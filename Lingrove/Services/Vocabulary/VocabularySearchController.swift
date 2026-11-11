import LingroveNotebook
import Combine
import Foundation

/// The app graph owns one search controller. Vocabulary and model settings borrow its download
/// state; the notebook activates indexing only while visible. Epochs reject work completed after
/// a query edit, collection change, model deletion or window closure.
@MainActor
final class VocabularySearchController: ObservableObject {
    @Published private(set) var status: VocabularySearchStatus = .notInstalled
    @Published private(set) var results = VocabularySearchResults()
    @Published private(set) var isSearching = false
    @Published private(set) var completedQuery: String?
    let downloads: ModelDownloadManager
    var openModelSettings: (() -> Void)?
    private let store: VocabularyStore
    private let index: VocabularySearchIndex
    private let directoryURL: URL
    private var subscriptions = Set<AnyCancellable>()
    private var indexing: Task<Void, Never>?
    private var searching: Task<Void, Never>?
    private var documents: [VocabularySearchDocument] = []
    private var meanings: [VocabularyMeaningSearchDocument] = []
    private var preparedRevision: UUID?
    private var completedRevision: UUID?
    private var reconciledEmbeddingRevision: UUID?
    private var reconciledModelURL: URL?
    private var epoch = UUID()
    private var queryEpoch = UUID()
    private var active = false
    private var query = ""
    private var language: LearningLanguage?
    private var tag = ""

    init(store: VocabularyStore, directoryURL: URL = VocabularySearchCatalog.directoryURL,
         cacheURL: URL? = VocabularySearchCatalog.cacheURL,
         downloads: ModelDownloadManager? = nil) {
        self.store = store
        self.directoryURL = directoryURL
        self.downloads = downloads ?? ModelDownloadManager(runtimeDirectoryURL: directoryURL,
            assetCatalog: [VocabularySearchCatalog.model])
        index = VocabularySearchIndex(cacheURL: cacheURL)
        store.$contentRevision.dropFirst()
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.refresh()
        }.store(in: &subscriptions)
        store.$scopeIdentity.dropFirst().sink { [weak self] identity in
            guard let self else { return }
            epoch = UUID(); queryEpoch = UUID(); indexing?.cancel(); searching?.cancel()
            documents = []; meanings = []; results = .init(); isSearching = false; completedQuery = nil
            preparedRevision = nil; completedRevision = nil; query = ""; language = nil; tag = ""
            reconciledEmbeddingRevision = nil; reconciledModelURL = nil
            Task { [weak self, index = self.index] in
                await index.unload(removingCache: true)
                guard let self, store.scopeIdentity == identity else { return }
                refresh()
            }
        }.store(in: &subscriptions)
        self.downloads.$modelStates.map { $0[VocabularySearchCatalog.model.id] }.removeDuplicates()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            // Progress repaints search/settings controls without restarting indexing per byte.
            let installed = self.downloads.isModelInstalled(VocabularySearchCatalog.model)
            if installed || self.status != .notInstalled { self.refresh() }
        }.store(in: &subscriptions)
    }

    var modelURL: URL? {
        downloads.isModelInstalled(VocabularySearchCatalog.model)
            ? directoryURL.appendingPathComponent(VocabularySearchCatalog.model.filename) : nil
    }

    func activate() {
        guard !active else { return }
        active = true
        downloads.refreshModelStates()
        refresh()
    }

    func suspend() {
        active = false
        epoch = UUID(); queryEpoch = UUID()
        indexing?.cancel(); searching?.cancel()
        indexing = nil; searching = nil; isSearching = false
        Task { await index.unload() }
    }

    func download() { downloads.download(VocabularySearchCatalog.model) }

    func removeModel() async {
        let wasActive = active
        suspend()
        await index.unload(removingCache: true)
        downloads.deleteModel(filename: VocabularySearchCatalog.model.filename)
        status = .notInstalled
        // Settings can delete while the vocabulary window is open. Rebuild keyword results and
        // leave the window active so a later explicit download restores hybrid search there.
        if wasActive { activate() }
    }

    func retry() { refresh() }

    func hasCurrentResults(for query: String) -> Bool {
        !isSearching && completedRevision == store.contentRevision &&
            completedQuery == String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
    }

    func search(_ query: String, language: LearningLanguage?, tag: String) {
        self.query = query; self.language = language; self.tag = tag
        runSearch()
    }

    private func refresh() {
        guard active else { return }
        epoch = UUID()
        queryEpoch = UUID(); isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let capturedEpoch = epoch
        indexing?.cancel(); searching?.cancel()
        let entries = store.entries, semantics = store.semantics, modelURL = modelURL, revision = store.contentRevision
        let entryChange = store.searchEntryChange
        indexing = Task { [weak self, index] in
            guard let prepared = try? await index.prepare(entries: entries, semantics: semantics,
                revision: revision, entryChange: entryChange) else { return }
            guard let self, self.epoch == capturedEpoch, !Task.isCancelled else { return }
            let documents = prepared.documents, meanings = prepared.meanings
            self.documents = documents
            self.meanings = meanings
            self.preparedRevision = revision
            // A classification/tag/display edit can change UI revision without changing any
            // embedding input. Only a completed reconcile may establish this reusable token.
            if let modelURL, self.status == .ready, self.reconciledModelURL == modelURL,
               self.reconciledEmbeddingRevision == prepared.embeddingRevision {
                self.runSearch()
                return
            }
            self.status = modelURL == nil ? .notInstalled : .indexing(completed: 0, total: documents.count + meanings.count)
            self.runSearch(usingModel: false)
            guard let modelURL else { return }
            do {
                try await index.reconcile(documents, meanings: meanings, modelURL: modelURL) { [weak self] completed, total in
                    await self?.progress(completed, total: total, epoch: capturedEpoch)
                }
                guard self.epoch == capturedEpoch, !Task.isCancelled else { return }
                self.reconciledEmbeddingRevision = prepared.embeddingRevision
                self.reconciledModelURL = modelURL
                self.status = .ready
                self.runSearch()
            } catch {
                guard self.epoch == capturedEpoch, !Task.isCancelled else { return }
                self.status = .failed(error.localizedDescription)
                self.runSearch(usingModel: false)
            }
        }
    }

    private func progress(_ completed: Int, total: Int, epoch: UUID) {
        guard self.epoch == epoch else { return }
        status = .indexing(completed: completed, total: total)
    }

    private func runSearch(usingModel: Bool = true) {
        queryEpoch = UUID(); searching?.cancel()
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
        guard active, !text.isEmpty else {
            results = .init(); isSearching = false; completedQuery = nil
            return
        }
        let documents = documents, meanings = meanings, language = language, tag = tag, revision = preparedRevision
        let queryID = queryEpoch
        let url = usingModel && status == .ready ? modelURL : nil
        isSearching = true
        searching = Task { [weak self, index] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                let results = try await index.search(text, documents: documents, meanings: meanings, modelURL: url,
                    language: language, tag: tag)
                guard let self, self.queryEpoch == queryID, !Task.isCancelled else { return }
                self.results = results; self.completedQuery = text; self.completedRevision = revision; self.isSearching = false
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled else { return }
                let fallback = try? await index.search(text, documents: documents, meanings: meanings, modelURL: nil,
                    language: language, tag: tag)
                guard let self, self.queryEpoch == queryID, !Task.isCancelled else { return }
                self.results = fallback ?? .init()
                self.completedQuery = text; self.completedRevision = revision; self.isSearching = false
                if url != nil { self.status = .failed(error.localizedDescription) }
            }
        }
    }
}
