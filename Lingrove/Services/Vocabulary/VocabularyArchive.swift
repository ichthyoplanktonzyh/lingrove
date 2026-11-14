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
    var hasCompleteBaseline: Bool { saved != nil }
    // The actor owns this rebuildable read index; it never authorizes a save or replaces SQL.
    var cliLiteralIndex = VocabularyLiteralSearchIndex()

    func checkCommandOwner(_ version: LingroveNotebookVersion) throws {
        if let expectedScope, !expectedScope.hasSameOwner(as: version) { throw VocabularyError.editConflict }
    }

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
        preparingFullSnapshot: Bool = true,
        _ operation: @Sendable (isolated VocabularyArchive) throws -> T
    ) throws -> T {
        let previous = expectedScope
        expectedScope = scope
        defer { expectedScope = previous }
        return try storageAccess(write: false) {
            if preparingFullSnapshot { _ = try readSnapshot() }
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
            // The connection's cache verifies the durable corpus clock as well as the header.
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
            return .init(current, joinedEntries: try engine.cachedNotebookEntries(for: .init(current)))
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

    /// A compound entry writer returns a complete checked result. Publish its bounded receipt
    /// while keeping this actor's next CAS baseline aligned with the committed revision.
    func acknowledgeEntryBatch(_ result: LingroveNotebookSnapshot) throws -> VocabularyArchiveSnapshot {
        saved = result
        return try committedSnapshot(result)
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
        let detail = try persistence().notebookEntryDetail(lookupKey: VocabularyPolicy.entryKey(capture))
        let entry = try VocabularyPolicy.entryForSave(capture, existing: detail.entry,
            interpretations: document.interpretations, now: Date())
        return try commitEntry(entry)
    }

    func commitEntry(_ entry: VocabularyEntry,
                     images: [String: Data] = [:]) throws -> VocabularyArchiveSnapshot {
        try storageAccess(write: true) {
            let baseline = try transactionBaseline()
            if let expectedScope, !expectedScope.hasSameOwner(as: baseline) { throw VocabularyError.editConflict }
            let result = try persistence().saveNotebookEntry(entry, basedOn: baseline, images: images)
            saved = result
            return try entryChange(result, from: baseline, entryID: entry.id)
        }
    }

    /// The archive retains its acknowledged baseline only after the engine's organization
    /// transaction succeeds. Sheet extensions never replace its private scope/cache directly.
    func commitOrganization(_ edit: VocabularyOrganizationEdit) throws -> VocabularyArchiveSnapshot {
        try storageAccess(write: true) {
            _ = try load()
            let baseline = try transactionBaseline()
            if let expectedScope, !expectedScope.hasSameOwner(as: baseline) { throw VocabularyError.editConflict }
            let result = try persistence().saveNotebookOrganization(edit, basedOn: baseline)
            saved = result
            return try committedSnapshot(result)
        }
    }

    func update(_ entry: VocabularyEntry, basedOn baseline: VocabularyEntry,
                importedImages: [String: Data] = [:]) throws -> VocabularyArchiveSnapshot {
        _ = try load()
        let engine = try persistence()
        guard let original = try engine.notebookEntryDetail(entryID: entry.id).entry else { throw VocabularyError.editConflict }
        // Warm editors use the same indexed ownership lookup as cold capture. Cached complete
        // content must not make a local edit normalize every unrelated headword key.
        if let owner = try engine.notebookEntryDetail(lookupKey: VocabularyPolicy.entryKey(entry)).entry,
           owner.id != entry.id { throw VocabularyError.invalidContent }
        let merged = try mergedEntry(entry, baseline: baseline, current: original)
        if merged.senses.isEmpty { return try remove(id: merged.id) }
        return try commitEntry(merged, images: importedImages)
    }

    /// Both full and certified local saves merge the editor's baseline against the current
    /// owner. The engine, rather than a partial UI draft, checks global key/ID ownership.
    func mergedEntry(_ entry: VocabularyEntry, baseline: VocabularyEntry, current original: VocabularyEntry) throws -> VocabularyEntry {
        guard baseline.id == entry.id,
              Set(entry.senses.map(\.id)).count == entry.senses.count,
              Set(entry.examples.map(\.id)).count == entry.examples.count else { throw VocabularyError.invalidContent }
        guard entry.language == original.language, entry.kind == original.kind,
              !VocabularyPolicy.normalized(entry.expression).isEmpty else { throw VocabularyError.invalidContent }
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
        for sense in merged.senses where !VocabularySenseContentPolicy.hasContent(sense) {
            // Old empty records remain readable and can be left untouched by another edit.
            // New or changed drafts need content before acquiring a saved sense identity.
            guard let before = original.senses.first(where: { $0.id == sense.id }),
                  try VocabularySaveLiteralEquality.equal(before, sense) else { throw VocabularyError.invalidContent }
        }
        return merged
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
        let baseline = try load()
        guard let scope = baseline.scope else { throw VocabularyError.invalidArchive }
        let result = try persistence().removeNotebookEntry(id, basedOn: scope)
        saved = result
        return try entryChange(result, from: scope, entryID: id)
    }

    func remove(_ capture: VocabularyCapture) throws -> VocabularyArchiveSnapshot {
        let document = try load().document
        guard let header = document.catalog.first(where: { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) }),
              var entry = VocabularyNotebookProjection.entry(header.id, in: document),
              let destination = VocabularySensePolicy.destination(capture, in: entry),
              let sense = entry.senses.firstIndex(where: { $0.id == destination.senseID }),
              let usage = destination.exampleID else {
            return .init(try transactionBaseline())
        }
        entry.senses[sense].examples.removeAll { $0.id == usage }
        return try commitEntry(entry)
    }

    func mergeSenses(entryID: UUID, source: UUID, target: UUID) throws -> VocabularyArchiveSnapshot {
        let document = try load().document
        guard var entry = VocabularyNotebookProjection.entry(entryID, in: document) else { throw VocabularyError.invalidContent }
        try VocabularySenseEditingPolicy.merge(source: source, into: target, in: &entry, now: Date())
        return try commitEntry(entry)
    }

    /// Capture undo state inside the same archive operation as the merge. No view owns a
    /// database snapshot or reads media directly, and failed commits publish no undo receipt.
    func mergeSensesWithUndo(entryID: UUID, source: UUID, target: UUID, expectedRevision: UInt64?)
        throws -> (VocabularyArchiveSnapshot, VocabularySenseMergeUndo) {
        let before = try load()
        if let expectedRevision, expectedRevision != before.revision { throw VocabularyError.editConflict }
        guard let original = VocabularyNotebookProjection.entry(entryID, in: before.document) else { throw VocabularyError.invalidContent }
        var entry = original
        try VocabularySenseEditingPolicy.merge(source: source, into: target, in: &entry, now: Date())
        let removedImages = Set(Self.imageReferences(.init(entries: [original])))
            .subtracting(Self.imageReferences(.init(entries: [entry])))
        guard let originalScope = before.scope else { throw VocabularyError.invalidArchive }
        let images = try imagesForUndo(removedImages, scope: originalScope)
        let saved = try commitEntry(entry)
        guard let scope = saved.scope else { throw VocabularyError.invalidArchive }
        let ids = Set(original.senses.flatMap { [$0.id] + $0.mergedFrom })
        let graph = before.document.semantics
        let owned = VocabularySemanticIndex(patterns: graph.patterns.filter { ids.contains($0.senseID) },
            mappings: graph.mappings.filter { ids.contains($0.senseID) })
        return (saved, .init(entry: original, ownedSemantics: owned, after: .init(scope), images: images,
            selection: .init(entryID: entryID, senseID: source)))
    }

    func undoSenseMerge(_ undo: VocabularySenseMergeUndo) throws -> VocabularyArchiveSnapshot {
        let current = try load()
        guard let scope = current.scope, scope.hasSameOwner(as: undo.after),
              current.revision == undo.after.revision else { throw VocabularyError.editConflict }
        let result = try persistence().saveNotebookEntries([undo.entry], basedOn: scope, images: undo.images,
            restoringOwnedSemantics: undo.ownedSemantics)
        return try acknowledgeEntryBatch(result)
    }

    func removeSense(entryID: UUID, senseID: UUID) throws -> VocabularyArchiveSnapshot {
        let baseline = try load()
        guard let scope = baseline.scope else { throw VocabularyError.invalidArchive }
        let result = try persistence().removeNotebookSense(senseID, from: entryID, basedOn: scope)
        saved = result
        return try entryChange(result, from: scope, entryID: entryID)
    }

    private func entryChange(_ result: LingroveNotebookSnapshot, from baseline: LingroveNotebookSnapshot,
                             entryID: UUID) throws -> VocabularyArchiveSnapshot {
        let receipt = try persistence().committedNotebookChange(for: .init(result))
        let entry = receipt?.updatedEntries.first { $0.id == entryID }
            ?? VocabularyNotebookProjection.entry(entryID, in: result.document)
        return .init(result, entryChange: .init(baseRevision: baseline.revision, entryID: entryID, entry: entry),
            committedChange: receipt)
    }

    /// A receipt is optional and version-fenced by the engine. Unknown/external reads still
    /// carry the complete document, so UI correctness never depends on cache availability.
    func committedSnapshot(_ saved: LingroveNotebookSnapshot) throws -> VocabularyArchiveSnapshot {
        .init(saved, committedChange: try persistence().committedNotebookChange(for: .init(saved)),
            joinedEntries: try persistence().cachedNotebookEntries(for: .init(saved)))
    }

    /// The selected notebook owns the tag's entire lifetime. One transaction updates all
    /// occurrences; source evidence, explanation/media and semantic links remain untouched.
    func removeTag(_ tag: String) throws -> VocabularyArchiveSnapshot {
        guard !tag.isEmpty, tag.utf8.count <= 200 else { throw VocabularyError.invalidContent }
        return try storageAccess(write: true) {
            _ = try load()
            let baseline = try transactionBaseline()
            if let expectedScope, !expectedScope.hasSameOwner(as: baseline) { throw VocabularyError.editConflict }
            let result = try persistence().removeNotebookTag(tag, basedOn: baseline)
            saved = result
            return try committedSnapshot(result)
        }
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
            return try committedSnapshot(result)
        }
    }

    func commitCLI(
        _ document: VocabularyDocument, images: [String: Data], receipt: VocabularyCLIReceipt, addingNewCaptureEntries: Bool
    ) throws -> LingroveNotebookCLICommit {
        let result = try persistence().saveNotebookCLI(document, basedOn: transactionBaseline(), images: images,
            receipt: receipt, addingNewCaptureEntries: addingNewCaptureEntries)
        saved = result.snapshot
        return result
    }

    /// The shared rule walks the complete graph without performing IO or selecting a tool.
    func validate(_ document: VocabularyDocument) throws {
        try VocabularyDocumentValidation.validate(document)
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
