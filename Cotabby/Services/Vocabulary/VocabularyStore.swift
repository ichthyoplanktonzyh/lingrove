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
    var openSelection: ((VocabularySelection?) -> Void)?
    /// Composition supplies cached annotations only; saving a favorite never starts a model.
    var enrichCapture: ((VocabularyCapture) -> VocabularyCapture)?
    private let archive: VocabularyArchive
    private var loadWork: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var savedKeys: Set<String> = []
    private var pendingCounts: [String: Int] = [:]
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

    /// Reuse the single in-flight load when a card requests a saved explanation before browsing.
    func load() async { loadIfNeeded(); await loadWork?.value }

    func contains(_ capture: VocabularyCapture) -> Bool {
        if capture.senseID != nil { return VocabularyPolicy.contains(capture, in: entries) }
        if capture.example == nil { return standaloneKeys.contains(VocabularyPolicy.captureKey(capture)) }
        return savedKeys.contains(VocabularyPolicy.captureKey(capture))
    }
    func isPending(_ capture: VocabularyCapture) -> Bool { pending.contains(VocabularyPolicy.captureKey(capture)) }

    func save(_ capture: VocabularyCapture) async {
        let enriched = enrichCapture?(capture) ?? capture
        await change(capture) { try await self.archive.save(enriched) }
    }

    func saveExplanation(_ record: LearningExplanationRecord) async {
        do { apply(try await archive.saveExplanation(record)) } catch { report(error) }
    }

    func explanation(for input: LearningExplanationInput, language: LearningLanguage) -> LearningExplanationRecord? {
        entries.lazy.flatMap { $0.explanations ?? [] }.last { $0.input == input && $0.language == language }
    }

    /// A record can be reused across identical contexts, but its write destination is explicit.
    /// In particular, two usages with different translation languages must not alias on adoption.
    func explanationDestination(_ capture: VocabularyCapture) -> VocabularyExplanationDestination? {
        guard let entry = entries.first(where: { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) }) else { return nil }
        return VocabularySensePolicy.destination(capture, in: entry)
    }

    func userMeaning(at destination: VocabularyExplanationDestination) -> String? {
        guard let entry = entries.first(where: { $0.id == destination.entryID }) else { return nil }
        if let id = destination.exampleID {
            return entry.examples.first { $0.id == id && $0.meaningOrigin == .user }?.meaning
        }
        guard let index = VocabularySensePolicy.index(destination.senseID, in: entry) else { return nil }
        let sense = entry.senses[index]
        return sense.meaningOrigin == .user ? sense.meaning : nil
    }

    func adoptExplanation(_ record: LearningExplanationRecord, at destination: VocabularyExplanationDestination) async -> Bool {
        guard let original = entries.first(where: { $0.id == destination.entryID }) else { return false }
        var edited = original
        if let exampleID = destination.exampleID {
            // A move can finish while the model runs. Stable usage identity resolves its current
            // owner; a late reply must never recreate the old sense or an already deleted usage.
            guard let owner = original.senses.firstIndex(where: { $0.examples.contains { $0.id == exampleID } }),
                  let index = original.senses[owner].examples.firstIndex(where: { $0.id == exampleID }),
                  LearningExplanationPolicy.input(LearningExplanationPolicy.capture(original, sense: original.senses[owner],
                    example: original.senses[owner].examples[index])) == record.input else { return false }
            edited.senses[owner].examples[index].meaning = record.result.meaning
            edited.senses[owner].examples[index].meaningLanguage = record.language
            edited.senses[owner].examples[index].meaningOrigin = .user
        } else {
            guard let owner = VocabularySensePolicy.index(destination.senseID, in: original),
                  original.senses[owner].isSavedWithoutContext,
                  LearningExplanationPolicy.input(LearningExplanationPolicy.capture(original, sense: original.senses[owner],
                    example: nil)) == record.input else { return false }
            edited.senses[owner].meaning = record.result.meaning
            edited.senses[owner].meaningLanguage = record.language
            edited.senses[owner].meaningOrigin = .user
        }
        return await update(edited, basedOn: original)
    }

    func mergeSenses(entryID: UUID, source: UUID, target: UUID) async -> Bool {
        do {
            apply(try await archive.mergeSenses(entryID: entryID, source: source, target: target))
            return true
        } catch { report(error); return false }
    }

    func moveExample(entryID: UUID, exampleID: UUID, source: UUID, target: UUID?) async -> Bool {
        do {
            apply(try await archive.moveExample(entryID: entryID, exampleID: exampleID, source: source, target: target))
            return true
        } catch { report(error); return false }
    }

    func createSense(entryID: UUID) async -> UUID? {
        let id = UUID()
        do { apply(try await archive.createSense(entryID: entryID, senseID: id)); return id } catch { report(error); return nil }
    }

    func removeSense(entryID: UUID, senseID: UUID) async -> Bool {
        do { apply(try await archive.removeSense(entryID: entryID, senseID: senseID)); return true } catch { report(error); return false }
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
        let destination = explanationDestination(capture)
        let selection = destination.map { VocabularySelection(entryID: $0.entryID, senseID: $0.senseID) }
        CotabbyLogger.learning.debug("Vocabulary open requested", metadata: [
            "sense_found": .stringConvertible(selection != nil), "handler_available": .stringConvertible(openSelection != nil)
        ])
        openSelection?(selection)
    }

    private func change(_ capture: VocabularyCapture, operation: () async throws -> VocabularySnapshot) async {
        let key = VocabularyPolicy.captureKey(capture)
        pendingCounts[key, default: 0] += 1
        if pendingCounts[key] == 1 { pending.insert(key) }
        defer {
            let remaining = (pendingCounts[key] ?? 1) - 1
            if remaining == 0 { pendingCounts.removeValue(forKey: key); pending.remove(key) } else { pendingCounts[key] = remaining }
        }
        do { apply(try await operation()) } catch { report(error) }
    }

    private func apply(_ snapshot: VocabularySnapshot) {
        guard !isLoaded || snapshot.revision >= revision else { return }
        entries = snapshot.document.entries
        standaloneKeys = Set(entries.flatMap { entry in
            entry.senses.filter(\.isSavedWithoutContext).map { _ in VocabularyPolicy.entryKey(entry) + ":standalone" }
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
