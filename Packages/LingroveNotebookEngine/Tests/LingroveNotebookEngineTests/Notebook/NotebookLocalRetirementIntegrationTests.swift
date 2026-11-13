import Foundation
import LingroveNotebook
import SQLite3
import Testing
@testable import LingroveNotebookEngine

/// Private SQLite lifetimes exercise the same cold command as the app. Retirement changes
/// material admission only: stable Notes, authored fields, Cards, schedules and events survive.
@MainActor
struct NotebookLocalRetirementIntegrationTests {
    @Test func coldNoteRetirementKeepsFieldsMemoryHistoryAndUnrelatedMaterials() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture), entry = try #require(saved.document.entries.first)
        let selection = VocabularySelection(entryID: entry.id, senseID: entry.senses[0].id)
        let sibling = VocabularySelection(entryID: entry.id, senseID: entry.senses[1].id)
        var type = ReviewNoteDefaults.type; type.id = UUID()
        let hint = ReviewNoteField(name: "Hint", source: .custom)
        type.fields.append(hint); type.templates[0].back += "<p>{{Hint}}</p>"
        type.templates.append(.init(name: "Recall", front: "{{Meaning}}", back: "{{Expression}}"))
        try fixture.db.saveReviewNoteType(type, expected: nil, scope: saved)
        let notes = try fixture.db.enrollReviewNotes(selections: [selection, sibling], type: type, scope: saved)
        let original = try #require(notes.first { $0.senseID == selection.senseID })
        var edited = original; edited.revision += 1
        edited.customFields[hint.id.uuidString.lowercased()] = "My retained hint"
        try fixture.db.saveReviewNote(edited, expected: original, scope: saved)
        let review = try fixture.db.loadBuiltInNotebookReview(scope: saved, now: Date())
        let target = try #require(review.noteCards.first { $0.value.note.id == original.id })
        _ = try fixture.db.submitReview(workspaceId: fixture.workspace, reviewSubmission: .init(cardId: target.key, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC", noteVersion: target.value.questionVersion(in: saved)))
        let cards = try storedCards(fixture), history = try fixture.db.cardStore.loadReviewEvents(workspaceId: fixture.workspace)
        let store = ReviewNoteStore(core: fixture.db.core)
        let members = try store.memberships(workspace: fixture.workspace)
        let definitions = try store.types(workspace: fixture.workspace)
        let links = try fixture.db.loadLingroveNotebookCardLinks(workspaceId: fixture.workspace)
        let journal = try journalCounts(fixture)
        let siblingCards = Set(members.filter { $0.noteID != original.id }.map(\.cardID))
        try fixture.reopen()
        // Any write to a surviving source's material would fail. A source retirement has no
        // reason to render a sibling or advance its Card/link revision.
        for id in siblingCards {
            try fixture.db.core.executeScript(sql: """
                CREATE TEMP TRIGGER protect_\(id.replacingOccurrences(of: "-", with: ""))
                BEFORE INSERT ON notebook_review_material_state WHEN NEW.card_id='\(id)'
                BEGIN SELECT RAISE(ABORT,'Unrelated material changed'); END;
                """, errorContext: "Protect surviving source")
        }
        let receipt = try #require(try fixture.db.tryRemoveNotebookSense(selection.senseID, from: selection.entryID,
            basedOn: .init(saved)))
        #expect(receipt.entry?.senses.count == 1 && fixture.db.core.notebookSaveCache == nil)
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: receipt.version) != nil)
        #expect(try storedCards(fixture) == cards)
        #expect(try fixture.db.cardStore.loadReviewEvents(workspaceId: fixture.workspace) == history)
        let current = ReviewNoteStore(core: fixture.db.core)
        #expect(try current.notes(version: receipt.version, senseIDs: [selection.senseID]) == [edited])
        #expect(try current.memberships(workspace: fixture.workspace) == members)
        #expect(try current.types(workspace: fixture.workspace) == definitions)
        #expect(try fixture.db.loadLingroveNotebookCardLinks(workspaceId: fixture.workspace) == links)
        #expect(try journalCounts(fixture) == journal)
        for member in members {
            #expect(try status(fixture, cardID: member.cardID) == (member.noteID == original.id ? "sourceMissing" : "ready"))
        }
        #expect(throws: (any Error).self) {
            try fixture.db.submitReview(workspaceId: fixture.workspace, reviewSubmission: .init(cardId: target.key, rating: .again,
                reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC", noteVersion: target.value.questionVersion(in: saved)))
        }
        try fixture.reopen()
        let complete = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        let after = try fixture.db.loadBuiltInNotebookReview(scope: complete, now: Date())
        #expect(complete.document.entries[0].senses.map(\.id) == [sibling.senseID])
        #expect(after.review.groups[selection.senseID]?.hasUnavailableMaterial == true)
        #expect(after.eligibleCardIDs.isDisjoint(with: Set(members.filter { $0.noteID == original.id }.map(\.cardID))))
        #expect(try storedCards(fixture) == cards && fixture.db.loadReviewEventCount() == history.count)
    }

    @Test func retiringMergedAliasesKeepsLegacyFacesAndExplicitlyRetainedExercises() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture), entry = try #require(saved.document.entries.first)
        let first = entry.senses[0], survivor = entry.senses[1]
        let selection = VocabularySelection(entryID: entry.id, senseID: first.id)
        _ = try fixture.db.enrollReviewNotes(selections: [selection], version: .init(saved))
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        _ = try fixture.db.addNotebookExercise(draft)
        let retained = try fixture.db.addNotebookExercise(LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection))
        let retainedLink = try #require(try fixture.db.lingroveNotebookCardLinkStore.load(workspaceId: fixture.workspace,
            cardId: retained.cardId).first)
        _ = try fixture.db.lingroveNotebookCardLinkStore.update(retainedLink, generatedContent: retainedLink.generatedContent,
            sourceRevision: saved.revision, allowingUnavailableMaterial: true)
        var document = saved.document, merged = survivor
        merged.mergedFrom = [first.id]; merged.examples = first.examples
        document.entries[0].senses = [merged]
        let baseline = try fixture.db.saveLingroveNotebook(document, basedOn: saved, restoringBackup: true)
        let links = try fixture.db.loadLingroveNotebookCardLinks(workspaceId: fixture.workspace), cards = try storedCards(fixture)
        let noteCardIDs = Set(try ReviewNoteStore(core: fixture.db.core).memberships(workspace: fixture.workspace).map(\.cardID))
        try fixture.reopen()
        let receipt = try #require(try fixture.db.tryRemoveNotebookSense(survivor.id, from: entry.id, basedOn: .init(baseline)))
        #expect(receipt.entry == nil && fixture.db.core.notebookSaveCache == nil)
        for link in links {
            let expected = !noteCardIDs.contains(link.cardId) && link.allowsUnavailableMaterial ? "retained" : "sourceMissing"
            #expect(try status(fixture, cardID: link.cardId) == expected)
        }
        #expect(try storedCards(fixture) == cards && fixture.db.loadLingroveNotebookCardLinks(workspaceId: fixture.workspace) == links)
        let complete = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        #expect(complete.document.entries.isEmpty && !complete.document.sources.isEmpty)
        let excluded = try fixture.db.cardStore.loadNotebookExcludedReviewCardIds(workspaceId: fixture.workspace)
        #expect(!excluded.contains(retained.cardId))
        #expect(noteCardIDs.isSubset(of: excluded))
    }

    @Test(arguments: ["material", "journal"])
    func failureRollsBackCorpusProofAndAllReviewState(stage: String) throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture), entry = try #require(saved.document.entries.first), sense = entry.senses[0]
        _ = try fixture.db.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: sense.id)], version: .init(saved))
        let cards = try storedCards(fixture), beforeStatus = try materialStatuses(fixture)
        try fixture.reopen()
        let table = stage == "material" ? "notebook_review_material_state" : "notebook_pending_rows"
        try fixture.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER reject_retirement BEFORE INSERT ON \(table)
            BEGIN SELECT RAISE(ABORT,'Synthetic retirement failure'); END;
            """, errorContext: "Inject retirement failure")
        #expect(throws: (any Error).self) { try fixture.db.tryRemoveNotebookSense(sense.id, from: entry.id, basedOn: .init(saved)) }
        #expect(try fixture.db.currentNotebookVersion() == .init(saved))
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: .init(saved)) != nil)
        #expect(try fixture.db.notebookEntryDetail(entryID: entry.id).entry == entry)
        #expect(try storedCards(fixture) == cards && materialStatuses(fixture) == beforeStatus)
        try fixture.db.core.executeScript(sql: "DROP TRIGGER reject_retirement;", errorContext: "Remove synthetic failure")
        #expect(try fixture.db.tryRemoveNotebookSense(sense.id, from: entry.id, basedOn: .init(saved)) != nil)
    }

    @Test func anotherWorkspaceAndStaleGenerationCannotReceiveRetirementWrites() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let original = try seed(fixture), entry = try #require(original.document.entries.first)
        let selection = VocabularySelection(entryID: entry.id, senseID: entry.senses[0].id)
        _ = try fixture.db.enrollReviewNotes(selections: [selection], version: .init(original))
        let foreign = UUID().uuidString.lowercased(); try fixture.addWorkspace(foreign)
        _ = try fixture.db.saveLingroveNotebook(original.document, basedOn: fixture.db.loadLingroveNotebook(workspaceId: foreign))
        try activate(fixture, workspace: foreign)
        let other = try fixture.db.loadLingroveNotebook(workspaceId: foreign)
        _ = try fixture.db.enrollReviewNotes(selections: [selection], version: .init(other))
        let foreignStatuses = try materialStatuses(fixture, workspace: foreign)
        try activate(fixture, workspace: fixture.workspace)
        let current = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        try fixture.reopen()
        #expect(throws: VocabularyError.editConflict) {
            try fixture.db.tryRemoveNotebookSense(selection.senseID, from: entry.id, basedOn: .init(original))
        }
        #expect(try fixture.db.tryRemoveNotebookSense(selection.senseID, from: entry.id, basedOn: .init(current)) != nil)
        #expect(try materialStatuses(fixture, workspace: foreign) == foreignStatuses)
        #expect(try fixture.db.notebookEntryDetail(entryID: entry.id).entry?.senses.count == 1)
    }

    @Test func malformedAffectedNoteTypeRejectsRetirementWithoutPublishingAnyWrite() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture), entry = try #require(saved.document.entries.first)
        _ = try fixture.db.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: entry.senses[0].id)], version: .init(saved))
        try fixture.reopen()
        // Definitions are review-domain state, so their corruption does not revoke the
        // canonical proof. The affected-definition check must still abort this transaction.
        try fixture.db.core.execute(sql: "UPDATE notebook_note_types SET payload_json='{' WHERE workspace_id=?",
            values: [.text(fixture.workspace)])
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: .init(saved)) != nil)
        #expect(throws: (any Error).self) {
            try fixture.db.tryRemoveNotebookSense(entry.senses[0].id, from: entry.id, basedOn: .init(saved))
        }
        #expect(try fixture.db.currentNotebookVersion() == .init(saved))
        #expect(try fixture.db.notebookEntryDetail(entryID: entry.id).entry == entry)
        #expect(try materialStatuses(fixture).allSatisfy { $0.hasSuffix(":ready") })
    }

    @Test func retirementSQLWorkDoesNotWalkUnrelatedReviewNotes() throws {
        func work(_ count: Int) throws -> RetirementSQLWork {
            let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
            let now = Date(timeIntervalSince1970: 1_793_000_000)
            let entries = (0..<count).map { index in
                VocabularyEntry(id: UUID(), expression: "word\(index)", dictionaryForm: "word\(index)", language: .english,
                    kind: .word, senses: [.init(id: UUID(), meaning: "Meaning", isSavedWithoutContext: true,
                        createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
            }
            let saved = try fixture.db.saveLingroveNotebook(.init(entries: entries),
                basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
            _ = try fixture.db.enrollReviewNotes(selections: entries.map { .init(entryID: $0.id, senseID: $0.senses[0].id) },
                version: .init(saved))
            try fixture.reopen()
            let probe = RetirementSQLWork()
            // One synchronous test owns this trace context until defer removes the callback.
            // The Core serializes its connection; no pointer escapes the registered lifetime.
            sqlite3_trace_v2(fixture.db.core.connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement else { return 0 }
                let value = Unmanaged<RetirementSQLWork>.fromOpaque(context).takeUnretainedValue()
                let prepared = OpaquePointer(statement)
                let steps = Int(sqlite3_stmt_status(prepared, SQLITE_STMTSTATUS_VM_STEP, 0))
                value.steps += steps
                if let sql = sqlite3_sql(prepared) { value.statements[String(cString: sql), default: 0] += steps }
                return 0
            }, Unmanaged.passUnretained(probe).toOpaque())
            defer { sqlite3_trace_v2(fixture.db.core.connection, 0, nil, nil) }
            #expect(try fixture.db.tryRemoveNotebookSense(entries[0].senses[0].id, from: entries[0].id, basedOn: .init(saved)) != nil)
            #expect(fixture.db.core.notebookSaveCache == nil)
            return probe
        }
        let small = try work(20), large = try work(400)
        print("RETIREMENT_SQL_WORK small=\(small.steps) large=\(large.steps)")
        if large.steps >= small.steps * 2 {
            for (sql, steps) in large.statements.sorted(by: { $0.value > $1.value }).prefix(8) {
                print("RETIREMENT_SQL_STATEMENT small=\(small.statements[sql] ?? 0) large=\(steps) sql=\(sql)")
            }
        }
        #expect(small.steps > 0 && large.steps < small.steps * 2, "Retiring one source must not scan every unrelated Note/Card")
    }

    private func seed(_ fixture: NotebookMediaDatabaseFixture) throws -> LingroveNotebookSnapshot {
        try fixture.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
    }

    private func storedCards(_ fixture: NotebookMediaDatabaseFixture) throws -> [Card] {
        try fixture.db.core.query(sql: "SELECT card_id FROM cards WHERE workspace_id=? ORDER BY card_id",
            values: [.text(fixture.workspace)]) {
            DatabaseCore.columnText(statement: $0, index: 0)
        }.map { try fixture.db.loadActiveCard(workspaceId: fixture.workspace, cardId: $0) }
    }

    private func status(_ fixture: NotebookMediaDatabaseFixture, cardID: String) throws -> String? {
        try fixture.db.core.scalarOptionalText(sql: "SELECT status FROM notebook_review_material_state WHERE workspace_id=? AND card_id=?",
            values: [.text(fixture.workspace), .text(cardID)])
    }

    private func materialStatuses(_ fixture: NotebookMediaDatabaseFixture, workspace: String? = nil) throws -> [String] {
        try fixture.db.core.query(sql: "SELECT card_id,status FROM notebook_review_material_state WHERE workspace_id=? ORDER BY card_id",
            values: [.text(workspace ?? fixture.workspace)]) {
            DatabaseCore.columnText(statement: $0, index: 0) + ":" + DatabaseCore.columnText(statement: $0, index: 1)
        }
    }

    private func journalCounts(_ fixture: NotebookMediaDatabaseFixture) throws -> [Int] {
        try ["notebook_card_link_operations", "notebook_held_card_operations", "notebook_review_operations"].map {
            try fixture.db.core.scalarInt(sql: "SELECT COUNT(*) FROM \($0) WHERE workspace_id=?", values: [.text(fixture.workspace)])
        }
    }

    private func activate(_ fixture: NotebookMediaDatabaseFixture, workspace: String) throws {
        try fixture.db.updateCloudSettings(cloudState: .linked, linkedUserId: fixture.owner, linkedWorkspaceId: workspace,
            activeWorkspaceId: workspace, linkedEmail: nil)
    }
}

/// One synchronous SQL-work assertion owns this callback state until tracing is removed.
private final class RetirementSQLWork {
    var steps = 0
    var statements: [String: Int] = [:]
}
