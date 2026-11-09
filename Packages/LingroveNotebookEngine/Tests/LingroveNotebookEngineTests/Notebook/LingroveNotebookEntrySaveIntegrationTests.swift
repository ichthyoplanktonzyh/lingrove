import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import LingroveNotebookSync
import Testing
@testable import LingroveNotebookEngine

/// Actual SQLite saves protect cache authority, relationships and journaling. Disposable local
/// workspaces need no account, service, TCC grant, benchmark or model runtime.
@MainActor
struct LingroveNotebookEntrySaveIntegrationTests {
    @Test("One-entry saves retain trusted rows/directory and ignore forged baseline documents")
    func trustedCacheAndLiteralRows() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        var source = Self.document()
        _ = try VocabularyClassificationCatalog.bundled().install(in: &source.classification, nodes: [])
        var saved = try f.engine.saveLingroveNotebook(source, basedOn: f.load())
        saved = try f.load()
        let lineage = try #require(f.engine.core.notebookSaveCache).lineage
        var entry = saved.document.entries[0]
        entry.senses[0].meaning = "cafe\u{0301}"
        entry.senses[0].note = "literal\0note"
        let forged = LingroveNotebookSnapshot(workspaceId: saved.workspaceId, notebookId: saved.notebookId,
            revision: saved.revision, document: VocabularyDocument(), generation: saved.generation)
        saved = try f.engine.saveNotebookEntry(entry, basedOn: forged)
        #expect(try #require(f.engine.core.notebookSaveCache).lineage == lineage)
        #expect(saved.document.classification == source.classification)
        #expect(saved.document.entries[1] == source.entries[1])
        #expect(saved.document.entries[0].senses[0].meaning.utf8.elementsEqual("cafe\u{0301}".utf8))
        #expect(saved.document.entries[0].senses[0].note.utf8.elementsEqual("literal\0note".utf8))
        try assertRows(f.engine, document: saved.document)
        let operation = try f.engine.core.scalarText(sql: "SELECT operation_id FROM notebook_pending_transactions WHERE revision=?",
            values: [.integer(Int64(saved.revision))])
        let families = try f.engine.core.query(sql: "SELECT entity FROM notebook_pending_rows WHERE operation_id=?", values: [.text(operation)]) {
            DatabaseCore.columnText(statement: $0, index: 0)
        }
        #expect(!families.contains("categories") && !families.contains("category_parents"))
        #expect(try f.load() == saved)
        #expect(try #require(f.engine.core.notebookSaveCache).lineage == lineage)
        try f.reopen()
        let reopened = try f.load()
        #expect(reopened.document.entries[0].senses[0].note.utf8.elementsEqual("literal\0note".utf8))
        try assertRows(f.engine, document: reopened.document)
    }

    @Test("Entry deltas match full rows/public intent across evidence, notes and ordering changes")
    func incrementalProjectionMatchesFullCodec() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        var saved = try f.engine.saveLingroveNotebook(Self.document(), basedOn: f.load())
        var entry = saved.document.entries[0]
        for edit in 0..<6 {
                switch edit {
            case 0:
                entry.senses[0].examples.append(.init(id: UUID(), sourceKind: .authored, text: "A new coffee example.",
                    translation: "new translation", ranges: [], completeness: .sentence, meaning: "", createdAt: Date()))
            case 1:
                entry.senses[0].examples[0].text = "Corrected coffee evidence."
            case 2:
                entry.senses[0].examples.removeFirst()
            case 3:
                entry.senses[0].examples[0].ranges = [.init(NSRange(location: 0, length: 1))]
            case 4:
                entry.senses[0].note = "A saved note."
            default:
                entry.senses[0].tags.append("a tag")
            }
            let state = try VocabularyEntrySaveState(validating: saved.document)
            let change = try state.replacing(entry)
            let projection = try VocabularyEntryRowProjection(VocabularyPersistenceCodec.encode(saved.document)).applying(change)
            try assertSameRows(projection.projection.rows(reviewTemplatesPresent: change.document.reviewTemplates != nil),
                VocabularyPersistenceCodec.encode(change.document))
            #expect(try VocabularyWirePublicIntent.hasChanges(change, notebookID: saved.notebookId) ==
                VocabularyWirePublicIntent.hasChanges(from: saved.document, to: change.document, notebookID: saved.notebookId))
            saved = try f.engine.saveNotebookEntry(entry, basedOn: saved)
            try assertRows(f.engine, document: saved.document)
            entry = saved.document.entries[0]
        }
        #expect(saved.document.sources.count == 4)
        #expect(try f.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM pragma_foreign_key_check", values: []) == 0)
    }

    @Test("External commits, raw corruption, rollback and account ABA invalidate trusted state")
    func invalidationAndCAS() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        var saved = try f.engine.saveLingroveNotebook(Self.document(), basedOn: f.load())
        saved = try f.load()
        let lineage = try #require(f.engine.core.notebookSaveCache).lineage
        let other = try LingroveNotebookEngine(databaseURL: f.url, mediaDirectoryURL: f.media)
        defer { try? other.close() }
        var external = saved.document
        external.entries[1].senses[0].note = "external commit"
        let committed = try other.saveLingroveNotebook(external, basedOn: saved)
        #expect(throws: VocabularyError.self) {
            try f.engine.saveNotebookEntry(saved.document.entries[0], basedOn: saved)
        }
        saved = try f.load()
        #expect(saved == committed)
        #expect(try #require(f.engine.core.notebookSaveCache).lineage != lineage)
        let pending = try f.pending()
        enum Rollback: Error { case expected }
        #expect(throws: Rollback.self) {
            try f.engine.core.inTransaction {
                try f.engine.core.execute(sql: "UPDATE notebook_collections SET payload_json='bad' WHERE workspace_id=?", values: [.text(f.workspace)])
                throw Rollback.expected
            }
        }
        #expect(f.engine.core.notebookSaveCache == nil)
        #expect(try f.load() == saved)
        try other.core.execute(sql: "UPDATE notebook_senses SET payload_json='bad' WHERE workspace_id=?", values: [.text(f.workspace)])
        #expect(throws: (any Error).self) {
            try f.engine.saveNotebookEntry(saved.document.entries[0], basedOn: saved)
        }
        #expect(try f.pending() == pending)
        // Restore only synthetic fixture bytes through the other connection, then retire scope.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for sense in saved.document.catalog.flatMap(\.senses) {
            try other.core.execute(sql: "UPDATE notebook_senses SET payload_json=? WHERE workspace_id=? AND id=?",
                values: [.text(String(decoding: try encoder.encode(sense), as: UTF8.self)), .text(f.workspace), .text(sense.id.uuidString)])
        }
        try other.updateCloudSettings(cloudState: .linked, linkedUserId: "synthetic-owner", linkedWorkspaceId: f.workspace, activeWorkspaceId: f.workspace, linkedEmail: nil)
        try other.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil, linkedWorkspaceId: nil, activeWorkspaceId: f.workspace, linkedEmail: nil)
        #expect(throws: VocabularyError.self) {
            try f.engine.saveNotebookEntry(saved.document.entries[0], basedOn: saved)
        }
        #expect(try f.pending() == pending)
    }

    @Test("A deferred reader stays pinned while another connection commits, then invalidates")
    func deferredReaderRemainsCoherent() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        let saved = try f.engine.saveLingroveNotebook(Self.document(), basedOn: f.load())
        let other = try LingroveNotebookEngine(databaseURL: f.url, mediaDirectoryURL: f.media)
        defer { try? other.close() }
        var next = saved.document
        next.entries[1].senses[0].note = "committed while the reader is pinned"
        var committed: LingroveNotebookSnapshot?
        try f.engine.core.inReadTransaction {
            #expect(try f.engine.lingroveNotebookStore.readSnapshot(workspaceId: f.workspace) == saved)
            committed = try other.saveLingroveNotebook(next, basedOn: saved)
            #expect(try f.engine.lingroveNotebookStore.readSnapshot(workspaceId: f.workspace) == saved)
        }
        #expect(try f.load() == committed)
        var entry = try #require(committed).document.entries[0]
        entry.senses[0].meaning = "a fresh entry edit"
        let current = try #require(committed)
        let result = try f.engine.saveNotebookEntry(entry, basedOn: current)
        #expect(result.document.entries[1].senses[0].note == "committed while the reader is pinned")
        try assertRows(f.engine, document: result.document)
    }

    @Test("Invalid relationships and cancelled entry saves leave SQL, media ownership and journal atomic")
    func cancellationAndInvalidInput() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        let saved = try f.engine.saveLingroveNotebook(Self.document(), basedOn: f.load())
        var entry = saved.document.entries[0]
        let pending = try f.pending()
        entry.senses[0].examples[0] = saved.document.entries[1].examples[0]
        #expect(throws: (any Error).self) { try f.engine.saveNotebookEntry(entry, basedOn: saved) }
        let cancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try f.engine.saveNotebookEntry(saved.document.entries[0], basedOn: saved)
                return false
            } catch is CancellationError { return true }
            catch { Issue.record(error); return false }
        }.value
        #expect(cancelled)
        #expect(try f.load() == saved)
        #expect(try f.pending() == pending)
        #expect(try f.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_media_assets", values: []) == 0)
    }

    @Test("An entry journal failure rolls back source/media ownership and retires prepared cache")
    func journalFailureRollsBackNarrowSave() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        let saved = try f.engine.saveLingroveNotebook(Self.document(), basedOn: f.load())
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        var entry = saved.document.entries[0]
        entry.senses[0].content = [.init(content: .image(image.reference, caption: "rollback fixture"))]
        let pending = try f.pending()
        try f.engine.core.executeScript(sql: """
            CREATE TRIGGER fail_entry_journal BEFORE INSERT ON notebook_pending_rows
            BEGIN SELECT RAISE(ABORT, 'synthetic entry journal failure'); END;
            """, errorContext: "Install fixture failure")
        #expect(throws: (any Error).self) {
            try f.engine.saveNotebookEntry(entry, basedOn: saved,
                images: [image.reference.filename: image.data])
        }
        #expect(f.engine.core.notebookSaveCache?.lineage == nil)
        #expect(try f.pending() == pending)
        #expect(try f.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_media_assets", values: []) == 0)
        #expect(try f.load() == saved)
        try f.engine.core.executeScript(sql: "DROP TRIGGER fail_entry_journal", errorContext: "Remove fixture failure")
        let committed = try f.engine.saveNotebookEntry(entry, basedOn: saved,
            images: [image.reference.filename: image.data])
        #expect(try LingroveNotebookMediaStore(core: f.engine.core).image(image.reference, scope: committed) == image.data)
    }

    @Test("Timestamp/private receipts stay private while literal authored text is public intent")
    func publicIntentRetainsCancellationSemantics() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        var document = Self.document()
        document.catalog[0].senses[0].review = .init(plan: .init(audioKinds: [.expression, .sentence]))
        var saved = try f.engine.saveLingroveNotebook(document, basedOn: f.load())
        var entry = saved.document.entries[0]
        entry.updatedAt = Date()
        let binding = AnkiNoteBinding(originSenseID: entry.senses[0].id, endpoint: "http://127.0.0.1:19680",
            profile: "synthetic", noteID: 1, model: "synthetic", deck: "synthetic", identityField: "ID",
            mapping: [.identity: "ID"], fields: ["ID": entry.senses[0].id.uuidString.lowercased()])
        entry.senses[0].review?.bindings = [binding]
        entry.senses[0].review?.activeBindingID = binding.id
        var change = try VocabularyEntrySaveState(validating: saved.document).replacing(entry)
        #expect(try !VocabularyWirePublicIntent.hasChanges(change, notebookID: saved.notebookId))
        #expect(try !VocabularyWirePublicIntent.hasChanges(from: saved.document, to: change.document, notebookID: saved.notebookId))
        saved = try f.engine.saveNotebookEntry(entry, basedOn: saved)
        #expect(try f.engine.core.scalarInt(sql: "SELECT has_public_change FROM notebook_pending_transactions WHERE revision=?",
            values: [.integer(Int64(saved.revision))]) == 0)
        entry = saved.document.entries[0]
        entry.senses[0].meaning = "caf\u{00e9}"
        saved = try f.engine.saveNotebookEntry(entry, basedOn: saved)
        entry = saved.document.entries[0]
        entry.senses[0].meaning = "cafe\u{0301}"
        change = try VocabularyEntrySaveState(validating: saved.document).replacing(entry)
        #expect(try VocabularyWirePublicIntent.hasChanges(change, notebookID: saved.notebookId))
        #expect(try VocabularyWirePublicIntent.hasChanges(from: saved.document, to: change.document, notebookID: saved.notebookId))
    }

    @Test("Narrow source refresh retains authored review material and immutable review history")
    func reviewAndMediaRetention() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        var saved = try f.engine.saveLingroveNotebook(Self.document(), basedOn: f.load())
        let selected = VocabularySelection(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selected)
        let enrollment = try #require(try f.engine.enrollNotebookSenses([draft], basedOn: saved).first)
        let exercise = try #require(try f.engine.lingroveNotebookReviewStore.exercises(enrollment).first)
        _ = try f.engine.submitNotebookRating(.init(cardId: exercise.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), basedOn: saved)
        let rated = try f.engine.loadActiveCard(workspaceId: f.workspace, cardId: exercise.cardId)
        _ = try f.engine.saveCard(workspaceId: f.workspace, input: .init(frontText: "authored prompt", backText: rated.backText, tags: []),
            cardId: exercise.cardId, mediaAssetIdsReadyForUpload: [])
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        var entry = saved.document.entries[0]
        entry.senses[0].meaning = "updated source answer"
        entry.senses[0].content = [.init(content: .image(image.reference, caption: "private fixture"))]
        saved = try f.engine.saveNotebookEntry(entry, basedOn: saved, images: [image.reference.filename: image.data])
        let card = try f.engine.loadActiveCard(workspaceId: f.workspace, cardId: exercise.cardId)
        #expect(card.frontText == "authored prompt" && card.reps == rated.reps && card.dueAt == rated.dueAt)
        #expect(try f.engine.loadReviewEventCount() == 1)
        #expect(try LingroveNotebookMediaStore(core: f.engine.core).image(image.reference, scope: saved) == image.data)
        try f.reopen()
        #expect(try f.engine.loadReviewEventCount() == 1)
        #expect(try f.engine.loadActiveCard(workspaceId: f.workspace, cardId: exercise.cardId).reps == rated.reps)
        try assertRows(f.engine, document: f.load().document)
    }

    @Test("Dev cutover keeps only the previously visible corpus and can be retried")
    func devCorpusMigration() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        var source = Self.document()
        source.entries[0].senses[0].note = "Keep this note."
        source.entries[0].senses[0].tags = ["saved"]
        source.entries[0].senses[0].savedAt = Date(timeIntervalSinceReferenceDate: 815_000_001)
        let hidden = source.entries[1].examples[0].copiedWithNewID()
        source.entries[0].senses[0].examples.append(hidden)
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        source.entries[0].senses[0].content = [.init(content: .image(image.reference, caption: "saved"))]
        let before = try f.engine.saveLingroveNotebook(source, basedOn: f.load(), images: [image.reference.filename: image.data])
        let visible = before.document.entries[0]
        let sense = visible.senses[0].id.uuidString, example = visible.examples[0].id
        let otherSense = before.document.entries[1].senses[0].id.uuidString
        try f.engine.core.inTransaction {
            try f.engine.core.execute(sql: "DELETE FROM notebook_collections WHERE workspace_id=? AND id=?",
                values: [.text(f.workspace), .text(otherSense)])
            let payload = String(decoding: try JSONEncoder().encode(example), as: UTF8.self)
            try f.engine.core.execute(sql: """
                INSERT INTO notebook_collection_interpretations(workspace_id,id,parent_id,position,payload_json,usage_id)
                VALUES(?,?,?,0,?,?)
                """, values: [.text(f.workspace), .text(sense + ":" + example.uuidString), .text(sense),
                              .text(payload), .text(example.uuidString)])
            try f.engine.core.executeScript(sql: "PRAGMA user_version=40;", errorContext: "Create Dev v40 fixture")
        }
        try f.engine.close()
        #expect(try LingroveNotebookStore.migrateDevCorpus(databaseURL: f.url, mediaDirectoryURL: f.media) == 1)
        #expect(try LingroveNotebookStore.migrateDevCorpus(databaseURL: f.url, mediaDirectoryURL: f.media) == 0)
        try f.reopen()
        var expected = visible
        expected.senses[0].examples = [visible.examples[0]]
        let after = try f.load()
        #expect(after.document.entries == [expected])
        #expect(after.revision == before.revision + 1)
        #expect(try LingroveNotebookMediaStore(core: f.engine.core).image(image.reference, scope: after) == image.data)
        #expect(try f.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM pragma_foreign_key_check", values: []) == 0)
    }

    private func assertRows(_ engine: LingroveNotebookEngine, document: VocabularyDocument) throws {
        let cached = try #require(engine.core.notebookSaveCache)
        try assertSameRows(cached.projection.rows(reviewTemplatesPresent: document.reviewTemplates != nil), VocabularyPersistenceCodec.encode(document))
    }
    private func assertSameRows(_ lhs: VocabularyPersistenceRows, _ rhs: VocabularyPersistenceRows) throws {
        let left = try lhs.keyedRows(), right = try rhs.keyedRows()
        #expect(left == right)
        for (key, row) in left { #expect(try row.encodedPayload() == right[key]?.encodedPayload()) }
    }
    private static func document() -> VocabularyDocument {
        let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
        return .init(entries: ["coffee", "river"].map { word in
            .init(id: UUID(), expression: word, dictionaryForm: word, language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: "meaning of " + word,
                    examples: [.init(id: UUID(), sourceKind: .authored, text: "An example of " + word + ".", translation: "translation",
                        ranges: [], completeness: .sentence, meaning: "", createdAt: now)], createdAt: now, updatedAt: now)],
                createdAt: now, updatedAt: now)
        })
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-w3-entry-save-" + UUID().uuidString)
        let url: URL, media: URL, workspace: String
        var engine: LingroveNotebookEngine
        init() throws {
            url = directory.appendingPathComponent("notebook.sqlite"); media = directory.appendingPathComponent("media")
            engine = try .init(databaseURL: url, mediaDirectoryURL: media)
            workspace = try engine.workspaceSettingsStore.loadWorkspace().workspaceId
        }
        func load() throws -> LingroveNotebookSnapshot { try engine.loadLingroveNotebook(workspaceId: workspace, requireActiveWorkspace: true) }
        func pending() throws -> Int { try engine.lingroveNotebookStore.pendingCount(workspaceId: workspace) }
        func reopen() throws { try engine.close(); engine = try .init(databaseURL: url, mediaDirectoryURL: media) }
        func cleanUp() { try? engine.close(); try? FileManager.default.removeItem(at: directory) }
    }
}
