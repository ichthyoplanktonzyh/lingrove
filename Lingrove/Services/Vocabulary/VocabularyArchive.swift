import LingroveNotebookEngine
import LingroveNotebook
import Darwin
import Foundation
import Logging

/// The app-owned vocabulary store borrows the repository's explicit file locations. Each
/// actor owns one private engine connection on that same physical SQLite file until shutdown;
/// it never receives the MainActor engine or a raw handle. Connection-owned, SQL-verified save
/// state can survive between commands, while the archive baseline still supplies explicit CAS.
actor VocabularyArchive {
    let url: URL?
    let mediaDirectoryURL: URL
    private let temporaryDirectory: URL?
    private var engine: LingroveNotebookEngine?
    private var isShutDown = false
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
            // The connection's cache verifies data_version/total_changes as well as the header.
            // A version-only actor cache would hide an external repair/corruption that did not
            // advance the notebook revision and let an editor prepare from stale content.
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
        guard let catalog = classificationCatalog else { return false }
        // This process-owned manifest was decoded once. An installed current framework needs no
        // repeated manifest-key set construction or definition work on every capture/commit.
        let frameworkID = VocabularyClassificationCatalog.identifier(catalog.key)
        if let current = document.classification.frameworks.first(where: { $0.id == frameworkID }),
           current.key == catalog.key, current.version >= catalog.version { return false }
        return try catalog.install(in: &document.classification, nodes: document.semantics.nodes)
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

    /// One actor-isolated connection retains trusted derived state. Commands are synchronous
    /// while it is borrowed; SQLite still owns transactions and checks external write tokens.
    /// App shutdown drains all accepted commands before retiring this connection.
    func storageAccess<T>(write: Bool, _ operation: () throws -> T) throws -> T {
        guard !isShutDown else { throw VocabularyError.editConflict }
        if engine == nil {
            guard let url else { throw VocabularyError.invalidArchive }
            engine = try LingroveNotebookEngine(databaseURL: url, mediaDirectoryURL: mediaDirectoryURL)
        }
        return try operation()
    }

    func shutdown() {
        isShutDown = true
        try? engine?.close()
        engine = nil; saved = nil
    }

    func save(_ capture: VocabularyCapture) throws -> VocabularyArchiveSnapshot {
        let document = try load().document
        let entry = try VocabularyPolicy.entryForSave(capture, in: document, now: Date())
        return try commitEntry(entry)
    }

    private func commitEntry(_ entry: VocabularyEntry,
                             images: [String: Data] = [:]) throws -> VocabularyArchiveSnapshot {
        try storageAccess(write: true) {
            let baseline = try transactionBaseline()
            if let expectedScope, !expectedScope.hasSameOwner(as: baseline) { throw VocabularyError.editConflict }
            let result = try persistence().saveNotebookEntry(entry, basedOn: baseline, images: images)
            saved = result
            return .init(result)
        }
    }

    func update(_ entry: VocabularyEntry, basedOn baseline: VocabularyEntry,
                importedImages: [String: Data] = [:]) throws -> VocabularyArchiveSnapshot {
        let document = try load().document
        guard let original = VocabularyNotebookProjection.entry(entry.id, in: document) else { throw VocabularyError.editConflict }
        guard baseline.id == entry.id,
              Set(entry.senses.map(\.id)).count == entry.senses.count,
              Set(entry.examples.map(\.id)).count == entry.examples.count else { throw VocabularyError.invalidContent }
        guard entry.language == original.language, entry.kind == original.kind,
              !VocabularyPolicy.normalized(entry.expression).isEmpty else { throw VocabularyError.invalidContent }
        guard !document.catalog.contains(where: { $0.id != entry.id && VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(entry) })
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
        if merged.senses.isEmpty { return try remove(id: merged.id) }
        return try commitEntry(merged, images: importedImages)
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
            guard try !VocabularySaveLiteralEquality.equal(value, before) else { continue }
            guard let index = result.firstIndex(where: { $0.id == value.id }) else { throw VocabularyError.editConflict }
            let live = result[index]
            var merged = live
            let meaning = try merge(VocabularyMeaning(text: before.meaning, language: before.meaningLanguage),
                VocabularyMeaning(text: live.meaning, language: live.meaningLanguage),
                VocabularyMeaning(text: value.meaning, language: value.meaningLanguage))
            merged.meaning = meaning.text; merged.meaningLanguage = meaning.language
            if merged.isSavedWithoutContext,
               !value.meaning.utf8.elementsEqual(before.meaning.utf8) || value.meaningLanguage != before.meaningLanguage,
               !merged.standaloneMeanings.contains(meaning) { merged.standaloneMeanings.append(meaning) }
            if !value.meaning.utf8.elementsEqual(before.meaning.utf8) || value.meaningLanguage != before.meaningLanguage ||
                value.meaningOrigin == .user && before.meaningOrigin != .user { merged.meaningOrigin = .user }
            merged.note = try merge(before.note, live.note, value.note)
            merged.tags = try merge(before.tags, live.tags, value.tags)
            merged.content = try merge(before.content, live.content, value.content)
            merged.examples = try mergeExamples(baseline: before.examples, current: live.examples, edited: value.examples)
            merged.updatedAt = Date()
            result[index] = merged
        }
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            if let live = result.first(where: { $0.id == before.id }), try !VocabularySaveLiteralEquality.equal(live, before) {
                throw VocabularyError.editConflict
            }
            result.removeAll { $0.id == before.id }
        }
        return result
    }

    private func merge<Value: Equatable & Encodable>(_ baseline: Value, _ current: Value, _ edited: Value) throws -> Value {
        guard try !VocabularySaveLiteralEquality.equal(edited, baseline) else { return current }
        guard try VocabularySaveLiteralEquality.equal(current, baseline) || VocabularySaveLiteralEquality.equal(current, edited) else {
            throw VocabularyError.editConflict
        }
        return edited
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
            guard try !VocabularySaveLiteralEquality.equal(example, before) else { continue }
            guard let index = merged.firstIndex(where: { $0.id == example.id }) else { throw VocabularyError.editConflict }
            var editedExample = correctedEvidence(example, before: before)
            if !example.text.utf8.elementsEqual(before.text.utf8), example.meaning.isEmpty {
                // The editor clears a stale sense when the source changes. That automatic clear
                // is not a user-authored blank; a new explanation may fill the new occurrence.
                editedExample.meaningOrigin = .captured
            } else if !example.meaning.utf8.elementsEqual(before.meaning.utf8) || example.meaningLanguage != before.meaningLanguage {
                editedExample.meaningOrigin = .user
            }
            merged[index] = try merge(before, merged[index], editedExample)
        }
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            if let item = merged.first(where: { $0.id == before.id }), try !VocabularySaveLiteralEquality.equal(item, before) {
                throw VocabularyError.editConflict
            }
            merged.removeAll { $0.id == before.id }
        }
        return merged
    }

    /// A correction is new evidence, while its interpretation retains the editor identity.
    /// Commit reconciliation withdraws stale mapping citations and requests confirmation;
    /// other interpretations continue citing the original immutable snapshot.
    private func correctedEvidence(_ example: VocabularyExample, before: VocabularyExample) -> VocabularyExample {
        var result = example
        if !example.text.utf8.elementsEqual(before.text.utf8) || example.appBundleIdentifier != before.appBundleIdentifier {
            result.sourceID = UUID(); result.sourceKind = .authored; result.occurrenceID = UUID()
        }
        if example.ranges != before.ranges { result.occurrenceID = UUID() }
        return result
    }

    func remove(id: UUID) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        next.entries.removeAll { $0.id == id }
        return try commit(next)
    }

    func remove(_ capture: VocabularyCapture) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        var entries = next.entries
        guard let entry = entries.firstIndex(where: { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) }),
              let destination = VocabularySensePolicy.destination(capture, in: entries[entry]),
              let sense = entries[entry].senses.firstIndex(where: { $0.id == destination.senseID }),
              let usage = destination.exampleID else {
            return .init(try transactionBaseline())
        }
        entries[entry].senses[sense].examples.removeAll { $0.id == usage }
        next.entries = entries
        return try commit(next)
    }

    func mergeSenses(entryID: UUID, source: UUID, target: UUID) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        try VocabularySenseEditingPolicy.merge(entryID: entryID, source: source, into: target, in: &next, now: Date())
        return try commit(next)
    }

    /// Capture undo state inside the same archive operation as the merge. No view owns a
    /// database snapshot or reads media directly, and failed commits publish no undo receipt.
    func mergeSensesWithUndo(entryID: UUID, source: UUID, target: UUID, expectedRevision: UInt64?)
        throws -> (VocabularyArchiveSnapshot, VocabularySenseMergeUndo) {
        let before = try load()
        if let expectedRevision, expectedRevision != before.revision { throw VocabularyError.editConflict }
        var next = before.document
        try VocabularySenseEditingPolicy.merge(entryID: entryID, source: source, into: target, in: &next, now: Date())
        let removedImages = Set(Self.imageReferences(before.document)).subtracting(Self.imageReferences(next))
        guard let originalScope = before.scope else { throw VocabularyError.invalidArchive }
        let images = try imagesForUndo(removedImages, scope: originalScope)
        let saved = try commit(next)
        guard let scope = saved.scope else { throw VocabularyError.invalidArchive }
        return (saved, .init(before: before.document, after: scope, images: images,
            selection: .init(entryID: entryID, senseID: source)))
    }

    func undoSenseMerge(_ undo: VocabularySenseMergeUndo) throws -> VocabularyArchiveSnapshot {
        let current = try load()
        guard let scope = current.scope, scope.hasSameOwner(as: undo.after),
              current.revision == undo.after.revision else { throw VocabularyError.editConflict }
        return try commitWithImages(undo.before, supplied: undo.images)
    }

    func moveExample(entryID: UUID, exampleID: UUID, source: UUID, target: UUID?) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        _ = try VocabularySensePolicy.move(exampleID: exampleID, from: source, to: target, in: &next.entries[index], now: Date())
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
        var entries = next.entries
        guard let entry = entries.firstIndex(where: { $0.id == entryID && $0.senses.contains { $0.id == senseID } }) else {
            throw VocabularyError.invalidContent
        }
        entries[entry].senses.removeAll { $0.id == senseID }
        if entries[entry].senses.isEmpty { entries.remove(at: entry) }
        next.entries = entries
        return try commit(next)
    }

    /// Review drafts use compare-and-swap rather than whole-entry replacement. A sheet cannot
    /// overwrite a newly merged binding or another window's review edits while HTTP is pending.
    func saveReview(entryID: UUID, senseID: UUID, value: VocabularyReview,
                    expected: VocabularyReview?, cardID: UUID? = nil,
                    importedImages: [String: Data] = [:]) throws -> VocabularyArchiveSnapshot {
        var next = try load().document
        guard let entry = next.entries.firstIndex(where: { $0.id == entryID }),
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
        // The lookup may finish after the user removes its destination. Resolve the
        // destination against the current corpus before attaching the explanation.
        guard let index = next.entries.firstIndex(where: { VocabularyPolicy.accepts(record, entry: $0) }) else {
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
