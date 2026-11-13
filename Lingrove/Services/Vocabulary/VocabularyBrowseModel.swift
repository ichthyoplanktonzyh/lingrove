import Combine
import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The store owns this independent read worker for its lifetime. Its read-only connection is
/// separate from the archive's serial full validation/write queue, so a long import or graph
/// preparation cannot put the next page behind an unrelated whole-corpus decode.
actor VocabularyBrowseIO {
    private let databaseURL: URL
    private let mediaDirectoryURL: URL
    private var engine: LingroveNotebookEngine?
    private var closed = false
    init(databaseURL: URL, mediaDirectoryURL: URL) {
        self.databaseURL = databaseURL; self.mediaDirectoryURL = mediaDirectoryURL
    }
    private func connection() throws -> LingroveNotebookEngine {
        guard !closed else { throw VocabularyError.editConflict }
        if let engine { return engine }
        let opened = try LingroveNotebookEngine(readOnlyDatabaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
        engine = opened; return opened
    }
    func page(_ query: NotebookBrowseQuery, after: NotebookBrowseCursor? = nil) throws -> NotebookBrowsePage {
        try connection().browseNotebook(query, after: after)
    }
    func detail(entryID: UUID? = nil, senseID: UUID? = nil, lookupKey: String? = nil,
                expected: NotebookBrowseFence? = nil) throws -> NotebookEntryDetail {
        try connection().notebookEntryDetail(entryID: entryID, senseID: senseID, lookupKey: lookupKey, expected: expected)
    }
    func tags(expected: NotebookBrowseFence) throws -> [String] { try connection().notebookBrowseTags(expected: expected) }
    func image(_ reference: VocabularyImageReference, detail: NotebookEntryDetail) throws -> Data {
        try connection().notebookEntryImage(reference, detail: detail)
    }
    func close() { closed = true; try? engine?.close(); engine = nil }
}

/// A bounded UI projection, never the complete VocabularyStore.entries. Views observe this
/// object directly; the store owns it and supplies metadata admission after every await.
/// Only one detail and the pages actually visited are retained. Global commands still use
/// the complete store, rather than treating these pages as the user's entire vocabulary.
@MainActor
final class VocabularyBrowseModel: ObservableObject {
    @Published private(set) var entries: [NotebookEntrySummary] = []
    @Published private(set) var total = 0
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var detail: VocabularyEntry?
    @Published private(set) var tags: [String] = []
    @Published private(set) var tagsReady = false
    @Published private(set) var error: String?
    private(set) var fence: NotebookBrowseFence?
    private(set) var decodedRows = 0
    private(set) var detailDecodedRows = 0
    private(set) var readDetail: NotebookEntryDetail?
    private var next: NotebookBrowseCursor?
    var hasMore: Bool { next != nil }
    let io: VocabularyBrowseIO
    private let repository: MacNotebookRepository?
    private var query = NotebookBrowseQuery()
    private var epoch = UUID()
    private var detailEpoch = UUID()
    private var requestedEntryID: UUID?
    private var requestedSenseID: UUID?
    private var tagsRequested = false
    private var tagsFence: NotebookBrowseFence?
    private var pageWork: Task<Void, Never>?
    private var detailWork: Task<Void, Never>?
    private var tagWork: Task<Void, Never>?
    private var active = false
    private var closed = false
    var onRead: ((NotebookBrowseFence) -> Bool)?

    init(databaseURL: URL, mediaDirectoryURL: URL, repository: MacNotebookRepository? = nil) {
        io = VocabularyBrowseIO(databaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
        self.repository = repository
    }

    func activate(_ query: NotebookBrowseQuery) {
        guard !closed else { return }
        active = true
        if self.query != query || !isReady && pageWork == nil { reload(query) }
    }

    func deactivate() { active = false }

    func reload(_ query: NotebookBrowseQuery? = nil, preservingWindow: Bool = false) {
        guard !closed else { return }
        let targetCount = preservingWindow ? max(100, entries.count) : 100
        if let query { self.query = query }
        epoch = UUID(); pageWork?.cancel(); detailEpoch = UUID(); detailWork?.cancel(); tagWork?.cancel()
        tagWork = nil
        next = nil; fence = nil; detail = nil; readDetail = nil
        if !preservingWindow { entries = []; total = 0 }
        isReady = false; isLoadingDetail = false; error = nil; decodedRows = 0
        readPage(after: nil, targetCount: targetCount)
    }

    func invalidate() { if active { reload(preservingWindow: true) } else { reset() } }

    func loadMoreIfNeeded(after id: UUID) {
        guard id == entries.last?.id, let next, pageWork == nil else { return }
        readPage(after: next)
    }

    func loadMore() { if let next, pageWork == nil { readPage(after: next) } }
    func waitForPage() async { await pageWork?.value }
    func waitForDetail() async { await detailWork?.value }
    func waitForTags() async { await tagWork?.value }

    private func admits(_ fence: NotebookBrowseFence) -> Bool {
        guard !closed else { return false }
        guard let repository else { return true }
        return (try? repository.engine.notebookBrowseFence()) == fence
    }

    // Keep cancellation, version admission and publication in one task body: moving the
    // guards away from their writes makes a resumed actor task harder to audit for races.
    // swiftlint:disable:next cyclomatic_complexity
    private func readPage(after cursor: NotebookBrowseCursor?, targetCount: Int = 100) {
        let identity = epoch, query = query
        isLoading = true
        pageWork = Task { [weak self] in
            guard let self else { return }
            do {
                var page = try await io.page(query, after: cursor)
                var incoming = page.entries, workRows = page.decodedRows
                // Refresh the visited window after a commit, rather than dropping a reader
                // on page ten back to page one. Old rows remain visible until replacement is
                // admitted, but never serve as a full document or a write-validation proof.
                while cursor == nil, incoming.count < targetCount, let next = page.next {
                    try Task.checkCancellation()
                    guard epoch == identity else { return }
                    page = try await io.page(query, after: next)
                    incoming += page.entries; workRows += page.decodedRows
                }
                guard !Task.isCancelled, epoch == identity else { return }
                guard admits(page.fence) else { reload(); return }
                guard onRead?(page.fence) != false else { return }
                // Tags are global metadata. Changing a list filter does not invalidate
                // them; only a different canonical corpus fence requires another scan.
                if tagsFence != page.fence { tags = []; tagsReady = false; tagsFence = nil }
                fence = page.fence
                if cursor == nil { entries = incoming } else { entries += incoming }
                total = page.total; next = page.next
                decodedRows += workRows; isReady = true; error = nil
                if requestedEntryID != nil || requestedSenseID != nil {
                    select(entryID: requestedEntryID, senseID: requestedSenseID)
                }
                if tagsRequested { loadTagsIfNeeded() }
            } catch {
                guard !Task.isCancelled, epoch == identity else { return }
                if cursor != nil, error as? VocabularyError == .editConflict { reload(); return }
                self.error = error.localizedDescription
            }
            guard epoch == identity else { return }
            isLoading = false; pageWork = nil
        }
    }

    // Selection has both a cached fast path and an admitted asynchronous path. Their shared
    // request identity prevents a delayed response from replacing a more recent selection.
    // swiftlint:disable:next cyclomatic_complexity
    func select(entryID: UUID? = nil, senseID: UUID? = nil) {
        guard !closed, entryID != nil || senseID != nil else { return }
        if isLoadingDetail, requestedEntryID == entryID, requestedSenseID == senseID { return }
        requestedEntryID = entryID; requestedSenseID = senseID
        if let detail, entryID == detail.id || senseID.map({ VocabularySensePolicy.index($0, in: detail) != nil }) == true { return }
        detailEpoch = UUID(); detailWork?.cancel()
        let identity = detailEpoch, expected = fence
        detail = nil; readDetail = nil; isLoadingDetail = true; detailDecodedRows = 0
        detailWork = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await io.detail(entryID: entryID, senseID: senseID, expected: expected)
                guard !Task.isCancelled, detailEpoch == identity else { return }
                guard admits(result.fence), fence == nil || fence == result.fence else { reload(); return }
                guard onRead?(result.fence) != false else { return }
                readDetail = result; detail = result.entry; detailDecodedRows = result.decodedRows; error = nil
            } catch {
                guard !Task.isCancelled, detailEpoch == identity else { return }
                if error as? VocabularyError == .editConflict { reload(); return }
                self.error = error.localizedDescription
            }
            if detailEpoch == identity { isLoadingDetail = false; detailWork = nil }
        }
    }

    func loadTagsIfNeeded() {
        tagsRequested = true
        guard !tagsReady, tagWork == nil, let fence else { return }
        let identity = epoch
        tagWork = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await io.tags(expected: fence)
                guard !Task.isCancelled, epoch == identity, admits(fence) else { return }
                tagsFence = fence; tags = result; tagsReady = true
            } catch {
                guard epoch == identity, !Task.isCancelled else { return }
                if error as? VocabularyError == .editConflict { reload(); return }
                self.error = error.localizedDescription
            }
            if epoch == identity { tagWork = nil }
        }
    }

    func reset() {
        epoch = UUID(); detailEpoch = UUID()
        pageWork?.cancel(); detailWork?.cancel(); tagWork?.cancel()
        pageWork = nil; detailWork = nil; tagWork = nil
        entries = []; detail = nil; readDetail = nil; tags = []; total = 0; fence = nil; next = nil
        tagsReady = false; tagsFence = nil; requestedEntryID = nil; requestedSenseID = nil; tagsRequested = false
        isReady = false; isLoading = false; isLoadingDetail = false; error = nil
    }

    func shutdown() async {
        closed = true
        let tasks = [pageWork, detailWork, tagWork]
        reset()
        for task in tasks { await task?.value }
        await io.close()
    }
}
