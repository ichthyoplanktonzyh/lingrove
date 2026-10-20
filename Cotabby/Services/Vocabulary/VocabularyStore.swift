import Combine
import Foundation
import Logging

/// The environment owns this UI-facing notebook for the process lifetime. Views observe saved
/// values and pending keys; the archive actor owns disk transactions. Monotonic revisions reject
/// a slow load response arriving after a newer save. Logs contain counts and IDs, never content.
@MainActor
final class VocabularyStore: ObservableObject {
    @Published private(set) var entries: [VocabularyEntry] = []
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var isLoaded = false
    @Published var errorMessage: String?
    var openEntry: ((UUID?) -> Void)?
    private let archive: VocabularyArchive
    private var loadWork: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var savedKeys: Set<String> = []
    private var entryIDs: [String: UUID] = [:]
    private var standaloneKeys: Set<String> = []

    init(archive: VocabularyArchive) { self.archive = archive }

    func loadIfNeeded() {
        guard !isLoaded, loadWork == nil else { return }
        loadWork = Task { [weak self, archive] in
            do {
                let snapshot = try await archive.load()
                self?.apply(snapshot)
            } catch { self?.report(error) }
            self?.loadWork = nil
        }
    }

    func contains(_ capture: VocabularyCapture) -> Bool {
        if capture.example == nil { return standaloneKeys.contains(VocabularyPolicy.captureKey(capture)) }
        return savedKeys.contains(VocabularyPolicy.captureKey(capture))
    }
    func isPending(_ capture: VocabularyCapture) -> Bool { pending.contains(VocabularyPolicy.captureKey(capture)) }

    func save(_ capture: VocabularyCapture) async {
        await change(capture) { try await self.archive.save(capture) }
    }

    func remove(_ capture: VocabularyCapture) async {
        CotabbyLogger.learning.debug("Vocabulary remove requested")
        await change(capture) { try await self.archive.remove(capture) }
    }

    func update(_ entry: VocabularyEntry, basedOn baseline: VocabularyEntry) async -> Bool {
        do { apply(try await archive.update(entry, basedOn: baseline)); return true } catch { report(error); return false }
    }

    func remove(id: UUID) async -> Bool {
        do { apply(try await archive.remove(id: id)); return true } catch { report(error); return false }
    }

    func export(to url: URL) async {
        do { try await archive.export(to: url) } catch { report(error) }
    }

    func show(_ capture: VocabularyCapture) {
        let id = entryIDs[VocabularyPolicy.entryKey(capture)]
        CotabbyLogger.learning.debug("Vocabulary open requested", metadata: [
            "entry_found": .stringConvertible(id != nil), "handler_available": .stringConvertible(openEntry != nil)
        ])
        openEntry?(id)
    }

    private func change(_ capture: VocabularyCapture, operation: () async throws -> VocabularySnapshot) async {
        let key = VocabularyPolicy.captureKey(capture)
        guard pending.insert(key).inserted else { return }
        defer { pending.remove(key) }
        do { apply(try await operation()) } catch { report(error) }
    }

    private func apply(_ snapshot: VocabularySnapshot) {
        guard !isLoaded || snapshot.revision >= revision else { return }
        entries = snapshot.document.entries
        entryIDs = Dictionary(entries.map { (VocabularyPolicy.entryKey($0), $0.id) }, uniquingKeysWith: { first, _ in first })
        standaloneKeys = Set(entries.flatMap { entry in
            entry.standaloneMeanings.map { VocabularyPolicy.entryKey(entry) + ":standalone:" + $0.id }
        })
        savedKeys = Set(entries.flatMap { entry in
            entry.examples.map { VocabularyPolicy.entryKey(entry) + ":" + VocabularyPolicy.exampleKey($0) }
        })
        revision = snapshot.revision
        isLoaded = true
        errorMessage = nil
        CotabbyLogger.learning.debug("Vocabulary updated", metadata: ["entry_count": .stringConvertible(entries.count)])
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        CotabbyLogger.learning.error("Vocabulary operation failed", metadata: ["error_type": .string(String(describing: type(of: error)))])
    }
}
