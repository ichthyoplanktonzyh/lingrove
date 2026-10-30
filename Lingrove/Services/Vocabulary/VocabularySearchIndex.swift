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
    private let cacheURL: URL?

    private struct Cache: Codable {
        let model: String
        let vectors: [String: [Float]]
    }

    init(cacheURL: URL?) { self.cacheURL = cacheURL }

    func documents(entries: [VocabularyEntry], semantics: VocabularySemanticIndex) -> [VocabularySearchDocument] {
        VocabularySearchPolicy.documents(entries: entries, semantics: semantics)
    }

    func reconcile(_ documents: [VocabularySearchDocument], modelURL: URL,
                   progress: @Sendable (Int, Int) async -> Void) async throws {
        restore()
        let keys = Set(documents.map(\.fingerprint))
        // Deletion and editing retire old vectors. The cache stores hashes, never saved text;
        // it is independent of the canonical archive and safe to remove or rebuild.
        vectors = vectors.filter { keys.contains($0.key) }
        for (position, document) in documents.enumerated() {
            try Task.checkCancellation()
            let key = document.fingerprint
            if vectors[key] == nil { vectors[key] = try embed(document.text, modelURL: modelURL) }
            if position % 10 == 0 || position + 1 == documents.count {
                await progress(position + 1, documents.count)
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
        var similarities: [UUID: Float] = [:]
        if let modelURL {
            let queryVector = try embed(VocabularySearchPolicy.queryText(query), modelURL: modelURL)
            for document in documents {
                try Task.checkCancellation()
                let key = document.fingerprint
                guard let vector = vectors[key] else { continue }
                similarities[document.id] = zip(queryVector, vector).reduce(0) { $0 + $1.0 * $1.1 }
            }
        }
        try Task.checkCancellation()
        return VocabularySearchPolicy.hits(documents: documents, query: query, similarities: similarities)
    }

    /// Native work has no suspension point, so unload cannot race a decode. The caller cancels
    /// its tasks first; a queued canceled search checks cancellation before touching the engine.
    func unload(removingCache: Bool = false) {
        engine.unloadModel()
        loadedURL = nil
        verifiedURL = nil
        if removingCache {
            vectors = [:]
            if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
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
        guard let cacheURL,
              let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1_024 * 1_024,
              let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.model == VocabularySearchCatalog.identity else { return }
        vectors = cache.vectors.filter { _, vector in
            vector.count == VocabularySearchCatalog.dimensions && vector.allSatisfy(\.isFinite) &&
                abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.01
        }
    }

    private func persist() {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Cache(model: VocabularySearchCatalog.identity, vectors: vectors))
            if data.count <= 64 * 1_024 * 1_024 { try data.write(to: cacheURL, options: .atomic) }
        } catch {
            // A derived-cache write failure must not disable an otherwise usable in-memory index.
            LingroveLogger.models.error("Vocabulary search cache write failed")
        }
    }

    private func unavailable() -> LearningFailure {
        .message(String(localized: "The search model could not be loaded. Download it again in model settings.", table: "Vocabulary"))
    }
}
