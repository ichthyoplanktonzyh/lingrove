import Combine
import Foundation

/// One import sheet owns one cancellable preview lifetime. Configuration changes invalidate
/// old work; only an explicit confirmation asks the app-owned store to commit validated inputs.
@MainActor
final class VocabularyWordListImportSession: ObservableObject {
    @Published private(set) var table: VocabularyWordList?
    @Published var configuration = VocabularyWordListConfiguration() {
        didSet { if table != nil { refreshPreview() } }
    }
    @Published private(set) var preview: VocabularyWordListPreview?
    @Published private(set) var preparing = true
    @Published private(set) var saving = false
    @Published private(set) var failure: String?
    private let store: VocabularyStore
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(store: VocabularyStore) { self.store = store }

    func load(_ source: URL, language: LearningLanguage) async {
        do {
            let table = try await store.readWordList(at: source)
            try Task.checkCancellation()
            self.table = table
            configuration = VocabularyWordListPolicy.configuration(for: table, language: language)
        } catch is CancellationError { return } catch { failure = error.localizedDescription; preparing = false }
    }

    func refreshPreview() {
        work?.cancel()
        generation = UUID()
        let id = generation
        preview = nil; failure = nil
        guard let table else { return }
        preparing = true
        let configuration = configuration
        work = Task { [weak self, store] in
            do {
                let preview = try await store.previewWordList(table, configuration: configuration)
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.preview = preview; self.preparing = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.failure = error.localizedDescription; self.preparing = false
            }
        }
    }

    func commit() async -> VocabularyEntryImportResult? {
        guard !preparing, !saving, let preview, preview.result.addedSenses > 0 else { return nil }
        saving = true; failure = nil
        defer { saving = false }
        do { return try await store.addEntries(preview.inputs) } catch { failure = error.localizedDescription; return nil }
    }

    func cancel() { work?.cancel(); generation = UUID(); preview = nil; preparing = false }
}
