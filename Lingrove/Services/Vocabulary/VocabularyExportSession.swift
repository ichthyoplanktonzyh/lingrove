import Combine
import Foundation

/// One export sheet owns this UI state and borrows the app-owned store. Preparation happens on
/// the archive actor; generation IDs discard late previews after a scope/options change or close.
@MainActor
final class VocabularyExportSession: ObservableObject {
    struct Key: Hashable { let scope: VocabularyExportScope; let configuration: VocabularyExportConfiguration }
    let store: VocabularyStore
    let request: VocabularyExportRequest
    @Published var scope: VocabularyExportScope
    @Published var configuration = VocabularyExportConfiguration()
    @Published private(set) var package: VocabularyExportPackage?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var message: String?
    private var generation = UUID()
    private var preparedKey: Key?
    private(set) var isActive = true

    init(store: VocabularyStore, request: VocabularyExportRequest) {
        self.store = store; self.request = request; scope = request.initialScope
    }
    var key: Key { .init(scope: scope, configuration: configuration) }
    var canExport: Bool { isActive && !loading && !saving && package != nil && preparedKey == key }

    func prepare() async {
        guard isActive else { return }
        let id = UUID(), key = key
        generation = id; loading = true; message = nil; package = nil; preparedKey = nil
        defer { if generation == id { loading = false } }
        do {
            let prepared = try await store.prepareExport(selections: request.selections(key.scope), configuration: key.configuration)
            try Task.checkCancellation()
            guard isActive, generation == id, self.key == key else { return }
            package = prepared; preparedKey = key
        } catch {
            if isActive, generation == id, !(error is CancellationError) { message = error.localizedDescription }
        }
    }

    func save(_ package: VocabularyExportPackage, to url: URL) async -> Bool {
        guard canExport, package.id == self.package?.id, package.configuration == configuration else { return false }
        saving = true; message = nil; defer { saving = false }
        do {
            try Task.checkCancellation()
            try await store.writeExport(package, to: url)
            return true
        } catch {
            if isActive, !(error is CancellationError) { message = error.localizedDescription }
            return false
        }
    }

    func cancel() { isActive = false; generation = UUID(); package = nil }
}
