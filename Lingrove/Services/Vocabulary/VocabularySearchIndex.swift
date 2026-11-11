import LingroveNotebook
import CotabbyInference
import Foundation
import Logging

/// This actor owns the native embedding context and rebuildable vector cache. Its serial executor
/// keeps C++ pointers off MainActor and out of concurrent decodes. Each document is one bounded
/// native operation; cancellation is checked between documents and before publishing a query.
actor VocabularySearchIndex {
    private var engine = CotabbyEmbeddingEngine()
    private var loadedURL: URL?
    private var verifiedURL: URL?
    private var vectors: [String: [Float]] = [:]
    private var restored = false
    private var cacheNeedsSave = false
    private let cache: VocabularySearchVectorCache?
    private var preparation = VocabularySearchPreparation()

    init(cacheURL: URL?) {
        cache = cacheURL.map { VocabularySearchVectorCache(url: $0, model: VocabularySearchCatalog.identity,
            dimensions: VocabularySearchCatalog.dimensions) }
    }

    func prepare(entries: [VocabularyEntry], semantics: VocabularySemanticIndex, revision: UUID? = nil,
                 entryChange: VocabularySearchEntryChange? = nil) throws -> VocabularySearchPreparation.Snapshot {
        try Task.checkCancellation()
        let value = preparation.prepare(entries: entries, semantics: semantics, revision: revision, entryChange: entryChange)
        try Task.checkCancellation()
        return value
    }

    func reconcile(_ documents: [VocabularySearchDocument], meanings: [VocabularyMeaningSearchDocument] = [], modelURL: URL,
                   progress: @Sendable (Int, Int) async -> Void) async throws {
        restore()
        // Sense and meaning vectors share one cache because the key describes the complete
        // embedding input. Existing sense vectors survive when a notebook gains meaning search.
        let inputs = documents.map { ($0.fingerprint, $0.text) } + meanings.map { ($0.fingerprint, $0.text) }
        let keys = Set(inputs.map { $0.0 })
        // Deletion and editing retire old vectors. The cache stores hashes, never saved text;
        // it is independent of the canonical archive and safe to remove or rebuild.
        let previousCount = vectors.count
        vectors = vectors.filter { keys.contains($0.key) }
        if previousCount != vectors.count { cacheNeedsSave = true }
        let missing = inputs.filter { vectors[$0.0] == nil }
        guard !missing.isEmpty || previousCount != vectors.count else {
            if cacheNeedsSave { persist() }
            return
        }
        for (position, (key, text)) in missing.enumerated() {
            try Task.checkCancellation()
            if vectors[key] == nil { vectors[key] = try embed(text, modelURL: modelURL); cacheNeedsSave = true }
            if position % 10 == 0 || position + 1 == missing.count {
                await progress(position + 1, missing.count)
            }
            // Yield even for cached rows so a large library cannot monopolize this actor and
            // delay cancellation, unloading, or keyword fallback while the window is interactive.
            await Task.yield()
        }
        try Task.checkCancellation()
        persist()
    }

    func search(_ query: String, documents: [VocabularySearchDocument], modelURL: URL?) throws -> [VocabularySearchHit] {
        try Task.checkCancellation()
        let queryVector = try modelURL.map { try embed(VocabularySearchPolicy.queryText(query), modelURL: $0) }
        let similarities = try scores(for: documents.map { ($0.id, $0.fingerprint) }, queryVector: queryVector)
        try Task.checkCancellation()
        return VocabularySearchPolicy.hits(documents: documents, query: query, similarities: similarities)
    }

    func search(_ query: String, documents: [VocabularySearchDocument], meanings: [VocabularyMeaningSearchDocument],
                modelURL: URL?, language: LearningLanguage? = nil, tag: String = "") throws -> VocabularySearchResults {
        try Task.checkCancellation()
        // Filter only after debounce, on the same actor as ranking. Keystrokes do no corpus
        // scan on MainActor, including when a large language/tag scope is selected.
        let documents = documents.filter { (language == nil || $0.language == language) && (tag.isEmpty || $0.tags.contains(tag)) }
        let allowed = Set(documents.map(\.id))
        let meanings = meanings.filter { $0.senseIDs.contains(where: allowed.contains) }
        let queryVector = try modelURL.map { try embed(VocabularySearchPolicy.queryText(query), modelURL: $0) }
        let similarities = try scores(for: documents.map { ($0.id, $0.fingerprint) }, queryVector: queryVector)
        let meaningSimilarities = try scores(for: meanings.map { ($0.id, $0.fingerprint) }, queryVector: queryVector)
        try Task.checkCancellation()
        return VocabularySearchPolicy.results(documents: documents, meanings: meanings, query: query,
            similarities: similarities, meaningSimilarities: meaningSimilarities)
    }

    private func scores(for inputs: [(UUID, String)], queryVector: [Float]?) throws -> [UUID: Float] {
        guard let queryVector else { return [:] }
        var similarities: [UUID: Float] = [:]
        for (id, fingerprint) in inputs {
            try Task.checkCancellation()
            guard let vector = vectors[fingerprint] else { continue }
            similarities[id] = zip(queryVector, vector).reduce(0) { $0 + $1.0 * $1.1 }
        }
        return similarities
    }

    /// Native work has no suspension point, so unload cannot race a decode. The caller cancels
    /// its tasks first; a queued canceled search checks cancellation before touching the engine.
    func unload(removingCache: Bool = false) {
        engine.unloadModel()
        loadedURL = nil
        verifiedURL = nil
        if removingCache {
            preparation = .init()
            vectors = [:]
            cacheNeedsSave = false
            cache?.remove()
        }
    }

    private func embed(_ text: String, modelURL: URL) throws -> [Float] {
        try Task.checkCancellation()
        if loadedURL != modelURL {
            // Download verification also covers resume paths. Validate a discovered file here
            // before native loading so a manually replaced same-name file is never trusted.
            if verifiedURL != modelURL {
                try ModelFileValidator.validateSize(of: modelURL, expectedBytes: VocabularySearchCatalog.model.expectedSizeBytes)
                try ModelFileValidator.validateSHA256(of: modelURL, expectedSHA256: VocabularySearchCatalog.model.sha256)
                verifiedURL = modelURL
            }
            try Task.checkCancellation()
            guard engine.loadModel(modelURL.path, 1_024) == .ok else { throw unavailable() }
            loadedURL = modelURL
        }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { throw unavailable() }
        let result = bytes.withUnsafeBufferPointer { buffer in
            // C++ copies token/input storage synchronously and returns an owning vector. No
            // pointer to Swift's temporary UTF-8 bytes survives this closure.
            // Nonempty UTF-8 above guarantees an address for this synchronous borrowed buffer.
            guard let address = buffer.baseAddress else { return engine.embed(nil, 0) }
            return address.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                engine.embed($0, Int32(buffer.count))
            }
        }
        let vector = Array(result)
        try Task.checkCancellation()
        guard vector.count == VocabularySearchCatalog.dimensions, vector.allSatisfy(\.isFinite) else { throw unavailable() }
        return vector
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        do { vectors = try cache?.load() ?? [:] } catch {
            vectors = [:]
            LingroveLogger.models.error("Vocabulary search cache restore failed")
        }
    }

    private func persist() {
        do { try cache?.save(vectors); cacheNeedsSave = false } catch {
            // Derived-cache failure never invalidates usable in-memory vectors or corpus data.
            LingroveLogger.models.error("Vocabulary search cache write failed")
        }
    }

    private func unavailable() -> LearningFailure {
        .message(String(localized: "The search model could not be loaded. Download it again in model settings.", table: "Vocabulary"))
    }
}
