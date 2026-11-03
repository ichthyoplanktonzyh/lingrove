import LingroveNotebookEngine
import LingroveNotebook
import Darwin
import Foundation
import Logging

/// The app-owned vocabulary store borrows the repository's explicit file locations. Each
/// synchronous command opens one short-lived engine on that same physical SQLite file and
/// closes it before returning; the actor never receives the MainActor engine or a raw handle.
/// Its cached baseline exists only to preserve CAS between pure preparation and commit.
actor VocabularyArchive {
    let url: URL?
    let mediaDirectoryURL: URL
    private let temporaryDirectory: URL?
    private var engine: LingroveNotebookEngine?
    private var saved: LingroveNotebookSnapshot?
    private var expectedScope: LingroveNotebookVersion?
    private let installsBundledClassification: Bool
    private var classificationCatalog: VocabularyClassificationCatalog?

    /// nil creates a disposable fixture, never a discovery path into the user's application.
    /// Production receives both immutable repository URLs through VocabularyStore(repository:).
    init(url: URL?, mediaDirectoryURL: URL? = nil, installsBundledClassification: Bool = false) {
        let database: URL
        if let url { database = url; temporaryDirectory = nil } else {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-notebook-" + UUID().uuidString)
            temporaryDirectory = temporary; database = temporary.appendingPathComponent("notebook.sqlite")
        }
        self.url = database
        self.mediaDirectoryURL = mediaDirectoryURL ?? database.deletingLastPathComponent()
            .appendingPathComponent(database.lastPathComponent + ".media")
        self.installsBundledClassification = installsBundledClassification
    }

    deinit { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }

    /// The isolated parameter lets the caller compose existing synchronous archive methods
    /// without transferring their connection. No await is possible inside this command body.
    func perform<T: Sendable>(
        basedOn scope: LingroveNotebookVersion?,
        _ operation: @Sendable (isolated VocabularyArchive) throws -> T
    ) throws -> T {
        let previous = expectedScope
        expectedScope = scope
        defer { expectedScope = previous }
        return try storageAccess(write: false) {
            _ = try readSnapshot()
            return try operation(self)
        }
    }

    func load() throws -> VocabularyArchiveSnapshot {
        try storageAccess(write: false) {
            let snapshot = try readSnapshot()
            var next = snapshot.document
            if try installClassification(in: &next) { return try commit(next) }
            return snapshot
        }
    }

    /// Re-reading can advance an ordinary field merge, but can never change the command's
    /// original workspace/notebook/generation. The actual writer checks this token again.
    func readSnapshot() throws -> VocabularyArchiveSnapshot {
        try storageAccess(write: false) {
            let engine = try persistence()
            let version = try engine.currentNotebookVersion()
            if let version, let expectedScope, !expectedScope.hasSameOwner(as: version) {
                throw VocabularyError.editConflict
            }
            // Restore the old revision cache, extended with book/account generation so an ABA
            // switch cannot reuse another lifetime's data. The writer still checks CAS in SQL.
            if let version, let saved, version == LingroveNotebookVersion(saved) { return .init(saved) }
            let workspace: String
            if let version { workspace = version.workspaceId } else {
                guard let active = try engine.workspaceSettingsStore.loadCloudSettings().activeWorkspaceId else {
                    throw VocabularyError.editConflict
                }
                workspace = active
            }
            let current = try engine.loadLingroveNotebook(workspaceId: workspace, requireActiveWorkspace: true)
            if let expectedScope, !expectedScope.hasSameOwner(as: current) { throw VocabularyError.editConflict }
            saved = current
            return .init(current)
        }
    }

    private func installClassification(in document: inout VocabularyDocument) throws -> Bool {
        guard installsBundledClassification else { return false }
        if classificationCatalog == nil { classificationCatalog = try .bundled() }
        return try classificationCatalog?.install(in: &document.classification, nodes: document.semantics.nodes) ?? false
    }

    func persistence() throws -> LingroveNotebookEngine {
        guard let engine else { throw VocabularyError.invalidArchive }
        return engine
    }

    func transactionBaseline() throws -> LingroveNotebookSnapshot {
        if let saved { return saved }
        _ = try readSnapshot()
        guard let saved else { throw VocabularyError.invalidArchive }
        return saved
    }

    /// This owns a connection lifetime, not a second transaction implementation. Public engine
    /// commands own BEGIN/CAS/COMMIT; nested archive helpers reuse only this synchronous handle.
    func storageAccess<T>(write: Bool, _ operation: () throws -> T) throws -> T {
        if engine != nil { return try operation() }
        guard let url else { throw VocabularyError.invalidArchive }
        let connection = try LingroveNotebookEngine(databaseURL: url, mediaDirectoryURL: mediaDirectoryURL)
        engine = connection
        defer { engine = nil; try? connection.close() }
        return try operation()
    }

    func save(_ capture: VocabularyCapture) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        _ = try VocabularyPolicy.save(capture, in: &next, now: Date())
        return try commit(next)
    }

    func update(_ entry: VocabularyEntry, basedOn baseline: VocabularyEntry,
                importedImages: [String: Data] = [:]) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entry.id }) else { throw VocabularyError.invalidContent }
        let original = next.entries[index]
        try validatePersonalEdit(entry, baseline: baseline, collections: next.collections)
        guard baseline.id == entry.id,
              Set(entry.senses.map(\.id)).count == entry.senses.count,
              Set(entry.examples.map(\.id)).count == entry.examples.count else { throw VocabularyError.invalidContent }
        guard entry.language == original.language, entry.kind == original.kind,
              !VocabularyPolicy.normalized(entry.expression).isEmpty else { throw VocabularyError.invalidContent }
        guard !next.entries.contains(where: { $0.id != entry.id && VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(entry) })
        else { throw VocabularyError.invalidContent }
        var merged = original
        merged.expression = try merge(baseline.expression, original.expression, entry.expression)
        merged.dictionaryForm = try merge(baseline.dictionaryForm, original.dictionaryForm, entry.dictionaryForm)
        merged.senses = try mergeSenses(baseline: baseline.senses, current: original.senses, edited: entry.senses)
        let priorOccurrences = Dictionary(grouping: original.examples, by: VocabularyPolicy.exampleKey)
        let editedOccurrences = Dictionary(grouping: merged.examples, by: VocabularyPolicy.exampleKey)
        guard editedOccurrences.allSatisfy({ key, values in
            values.count <= 1 || values.count <= (priorOccurrences[key]?.count ?? 0)
        }) else { throw VocabularyError.editConflict }
        merged.updatedAt = Date()
        next.entries[index] = merged
        for before in baseline.senses {
            guard let edited = entry.senses.first(where: { $0.id == before.id }) else {
                next.collections.removeAll { $0.senseID == before.id }; continue
            }
            let removed = Set(before.examples.map(\.id)).subtracting(edited.examples.map(\.id))
            if let collection = next.collections.firstIndex(where: { $0.senseID == before.id }) {
                next.collections[collection].interpretationIDs.removeAll { removed.contains($0) }
            }
        }
        return try commitWithImages(next, supplied: importedImages)
    }

    /// A sheet edits one sense while cards may append another. Merge by stable IDs and fields;
    /// an explicit conflict is safer than losing a concurrent note, move or user-authored meaning.
    private func mergeSenses(baseline: [VocabularySense], current: [VocabularySense],
                             edited: [VocabularySense]) throws -> [VocabularySense] {
        var result = current
        for value in edited {
            guard let before = baseline.first(where: { $0.id == value.id }) else {
                guard !result.contains(where: { $0.id == value.id || $0.mergedFrom.contains(value.id) }) else {
                    throw VocabularyError.editConflict
                }
                result.append(value); continue
            }
            guard value != before else { continue }
            guard let index = result.firstIndex(where: { $0.id == value.id }) else { throw VocabularyError.editConflict }
            let live = result[index]
            var merged = live
            let meaning = try merge(VocabularyMeaning(text: before.meaning, language: before.meaningLanguage),
                VocabularyMeaning(text: live.meaning, language: live.meaningLanguage),
                VocabularyMeaning(text: value.meaning, language: value.meaningLanguage))
            merged.meaning = meaning.text; merged.meaningLanguage = meaning.language
            if merged.isSavedWithoutContext, value.meaning != before.meaning || value.meaningLanguage != before.meaningLanguage,
               !merged.standaloneMeanings.contains(meaning) { merged.standaloneMeanings.append(meaning) }
            if value.meaning != before.meaning || value.meaningLanguage != before.meaningLanguage ||
                value.meaningOrigin == .user && before.meaningOrigin != .user { merged.meaningOrigin = .user }
            merged.note = try merge(before.note, live.note, value.note)
            merged.tags = try merge(before.tags, live.tags, value.tags)
            merged.content = try merge(before.content, live.content, value.content)
            merged.examples = try mergeExamples(baseline: before.examples, current: live.examples, edited: value.examples)
            merged.updatedAt = Date()
            result[index] = merged
        }
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            if let live = result.first(where: { $0.id == before.id }), live != before { throw VocabularyError.editConflict }
            // An editor removes a personal collection relationship, not the catalog sense.
        }
        return result
    }

    private func merge<Value: Equatable>(_ baseline: Value, _ current: Value, _ edited: Value) throws -> Value {
        guard edited != baseline else { return current }
        guard current == baseline || current == edited else { throw VocabularyError.editConflict }
        return edited
    }

    /// A detached editor cannot recreate personal state after an agent or another window
    /// uncollects it. Unchanged hidden senses can remain in the editor's stale baseline.
    private func validatePersonalEdit(_ entry: VocabularyEntry, baseline: VocabularyEntry,
                                      collections: [VocabularyCollectionItem]) throws {
        let ids = Set(collections.map(\.senseID))
        guard entry.senses.contains(where: { ids.contains($0.id) }) else { throw VocabularyError.editConflict }
        for sense in entry.senses {
            if let before = baseline.senses.first(where: { $0.id == sense.id }), sense != before, !ids.contains(sense.id) {
                throw VocabularyError.editConflict
            }
        }
    }

    /// Example IDs distinguish edits/deletions from captures appended after the editor opened.
    /// Newly typed examples deduplicate by their content; an unrelated live capture is preserved.
    private func mergeExamples(baseline: [VocabularyExample], current: [VocabularyExample],
                               edited: [VocabularyExample]) throws -> [VocabularyExample] {
        var merged = current
        for example in edited {
            guard let before = baseline.first(where: { $0.id == example.id }) else {
                if !merged.contains(where: { VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(example) }) {
                    merged.append(example)
                }
                continue
            }
            guard example != before else { continue }
            guard let index = merged.firstIndex(where: { $0.id == example.id }) else { throw VocabularyError.editConflict }
            var editedExample = correctedEvidence(example, before: before)
            if example.text != before.text, example.meaning.isEmpty {
                // The editor clears a stale sense when the source changes. That automatic clear
                // is not a user-authored blank; a new explanation may fill the new occurrence.
                editedExample.meaningOrigin = .captured
            } else if example.meaning != before.meaning || example.meaningLanguage != before.meaningLanguage {
                editedExample.meaningOrigin = .user
            }
            merged[index] = try merge(before, merged[index], editedExample)
        }
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            if let item = merged.first(where: { $0.id == before.id }), item != before { throw VocabularyError.editConflict }
            // Uncollect below the entry merge; keep the interpretation available to agents.
        }
        return merged
    }

    /// A correction is new evidence, while its interpretation retains the editor identity.
    /// Commit reconciliation withdraws stale mapping citations and requests confirmation;
    /// other interpretations continue citing the original immutable snapshot.
    private func correctedEvidence(_ example: VocabularyExample, before: VocabularyExample) -> VocabularyExample {
        var result = example
        if example.text != before.text || example.appBundleIdentifier != before.appBundleIdentifier {
            result.sourceID = UUID(); result.sourceKind = .authored; result.occurrenceID = UUID()
        }
        if example.ranges != before.ranges { result.occurrenceID = UUID() }
        return result
    }

    /// Notebook deletion removes personal membership. Catalog identities, raw evidence and
    /// interpretations remain addressable to an agent until an explicit resource deletion.
    func remove(id: UUID) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        let senseIDs = Set(next.catalog.first { $0.id == id }?.senses.map(\.id) ?? [])
        next.collections.removeAll { senseIDs.contains($0.senseID) }
        return try commit(next)
    }

    func remove(_ capture: VocabularyCapture) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let entry = next.collectedEntries.first(where: { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) }),
              let destination = VocabularySensePolicy.destination(capture, in: entry),
              let index = next.collections.firstIndex(where: { $0.senseID == destination.senseID }) else {
            return .init(try transactionBaseline())
        }
        if let id = destination.exampleID { next.collections[index].interpretationIDs.removeAll { $0 == id } } else {
            next.collections[index].isSavedWithoutContext = false
        }
        let collection = next.collections[index]
        if collection.interpretationIDs.isEmpty, !collection.isSavedWithoutContext, collection.note.isEmpty,
           collection.tags.isEmpty, (collection.content ?? []).isEmpty, collection.review == nil,
           (collection.reviewCards ?? []).isEmpty {
            next.collections.remove(at: index)
        }
        return try commit(next)
    }

    func mergeSenses(entryID: UUID, source: UUID, target: UUID) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        let selected = next.collections.first { $0.senseID == source }?.interpretationIDs ?? []
        try VocabularySensePolicy.merge(source: source, into: target, in: &next.entries[index], now: Date())
        for id in selected { VocabularyNotebookProjection.collect(senseID: target, interpretationID: id, in: &next, now: Date()) }
        return try commit(next)
    }

    func moveExample(entryID: UUID, exampleID: UUID, source: UUID, target: UUID?) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        let wasCollected = next.collections.first { $0.senseID == source }?.interpretationIDs.contains(exampleID) == true
        let targetID = try VocabularySensePolicy.move(exampleID: exampleID, from: source, to: target, in: &next.entries[index], now: Date())
        if wasCollected { VocabularyNotebookProjection.collect(senseID: targetID, interpretationID: exampleID, in: &next, now: Date()) }
        return try commit(next)
    }

    func createSense(entryID: UUID, senseID: UUID) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        let now = Date()
        next.entries[index].senses.append(VocabularySense(id: senseID, meaning: "", createdAt: now, updatedAt: now))
        next.entries[index].updatedAt = now
        return try commit(next)
    }

    func removeSense(entryID: UUID, senseID: UUID) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard next.catalog.contains(where: { $0.id == entryID && $0.senses.contains { $0.id == senseID } }) else {
            throw VocabularyError.invalidContent
        }
        next.collections.removeAll { $0.senseID == senseID }
        return try commit(next)
    }

    /// Review drafts use compare-and-swap rather than whole-entry replacement. A sheet cannot
    /// overwrite a newly merged binding or another window's review edits while HTTP is pending.
    func saveReview(entryID: UUID, senseID: UUID, value: VocabularyReview,
                    expected: VocabularyReview?, cardID: UUID? = nil,
                    importedImages: [String: Data] = [:]) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard next.collections.contains(where: { $0.senseID == senseID }),
              let entry = next.entries.firstIndex(where: { $0.id == entryID }),
              let sense = next.entries[entry].senses.firstIndex(where: { $0.id == senseID }),
              next.entries[entry].senses[sense].reviewValue(cardID) == expected else { throw VocabularyError.editConflict }
        guard cardID == nil || value.plan.id == cardID else { throw VocabularyError.invalidContent }
        next.entries[entry].senses[sense].setReview(value, cardID: cardID)
        return try commitWithImages(next, supplied: importedImages)
    }

    /// A merge may finish during a network write. Resolve the retired sense ID, keep the latest
    /// draft intact, and append the verified receipt. Deleted senses are never resurrected.
    func recordAnkiBinding(
        entryID: UUID, senseID: UUID, binding: AnkiNoteBinding, cardID: UUID? = nil
    ) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let entry = next.entries.firstIndex(where: { $0.id == entryID }),
              let sense = VocabularySensePolicy.index(senseID, in: next.entries[entry]),
              var review = next.entries[entry].senses[sense].reviewValue(cardID) else { throw VocabularyError.editConflict }
        if let index = review.bindings.firstIndex(where: { $0.id == binding.id }) { review.bindings[index] = binding } else {
            review.bindings.append(binding)
            if review.bindings.count > 1 { review.activeBindingID = nil }
        }
        if review.bindings.count == 1 { review.activeBindingID = binding.id }
        next.entries[entry].senses[sense].setReview(review, cardID: cardID)
        return try commit(next)
    }

    func export(to destination: URL) throws {
        try validateBackupDestination(destination)
        let data = try Self.encoded(load().document)
        try writeAtomically(data, to: destination)
    }

    func saveExplanation(_ record: LearningExplanationRecord) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        // Uncollecting retains catalog evidence. That historical knowledge is not permission
        // to persist a new floating explanation: only a currently saved destination may receive it.
        guard let collected = next.collectedEntries.first(where: { VocabularyPolicy.accepts(record, entry: $0) }),
              let index = next.entries.firstIndex(where: { $0.id == collected.id }) else {
            return .init(try transactionBaseline())
        }
        VocabularyPolicy.storeExplanation(record, in: &next.entries[index])
        return try commit(next)
    }

    func commit(_ document: VocabularyDocument, receipt: VocabularyCLIReceipt? = nil,
                restoringBackup: Bool = false) throws -> VocabularyArchiveSnapshot {
        try commitWithImages(document, supplied: [:], receipt: receipt, restoringBackup: restoringBackup)
    }

    /// The engine performs normalization, relationship validation, media authorization, journal
    /// and built-in material refresh in its existing transaction. We advance no UI cache on error.
    func commitUsingEngine(
        _ document: VocabularyDocument, images: [String: Data], receipt: VocabularyCLIReceipt?, restoringBackup: Bool
    ) throws -> VocabularyArchiveSnapshot {
        try storageAccess(write: true) {
            let baseline = try transactionBaseline()
            if let expectedScope, !expectedScope.hasSameOwner(as: baseline) { throw VocabularyError.editConflict }
            var next = document
            _ = try installClassification(in: &next)
            let result: LingroveNotebookSnapshot
            if let receipt {
                result = try persistence().saveNotebookCLI(next, basedOn: baseline, images: images, receipt: receipt).snapshot
            } else {
                result = try persistence().saveLingroveNotebook(next, basedOn: baseline, restoringBackup: restoringBackup,
                    images: images, requireActiveWorkspace: true)
            }
            saved = result
            return .init(result)
        }
    }

    func commitCLI(
        _ document: VocabularyDocument, images: [String: Data], receipt: VocabularyCLIReceipt
    ) throws -> LingroveNotebookCLICommit {
        let result = try persistence().saveNotebookCLI(document, basedOn: transactionBaseline(), images: images, receipt: receipt)
        saved = result.snapshot
        return result
    }

    /// The shared rule walks the complete graph without performing IO or selecting a tool.
    func validate(_ document: VocabularyDocument) throws {
        try VocabularyDocumentValidation.validate(document)
    }

    func validateReview(_ review: VocabularyReview) throws {
        try VocabularyReviewValidation.validate(review)
    }

    private static func encoded(_ document: VocabularyDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Stage with owner-only permissions, synchronize and atomically rename within the same
    /// directory. No fallible operation follows the commit, so UI and disk cannot disagree after
    /// a successful rename. The actor is the sole in-process writer for this file.
    /// Export may cancel before commit; notebook edits retain their existing transaction semantics
    /// even if their originating view disappears while the write is finishing.
    func writeAtomically(_ data: Data, to url: URL, cancellable: Bool = false) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".notebook-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        if cancellable { try Task.checkCancellation() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if cancellable { try Task.checkCancellation() }
        func publishFile() throws {
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        if expectedScope != nil {
            // Encoding/fsync above hold no SQL transaction. Only the final scope check and
            // atomic rename borrow the writer lock, so account retirement cannot interleave
            // between authorization and publishing bytes from a prepared old-account export.
            guard let current = try readSnapshot().scope else { throw VocabularyError.editConflict }
            let core = try persistence().core
            try core.inTransaction {
                try LingroveNotebookBackupStore(core: core).checkInTransaction(.init(workspaceId: current.workspaceId,
                    notebookId: current.notebookId, revision: current.revision, generation: current.generation))
                try publishFile()
            }
        } else { try publishFile() }
    }
}
