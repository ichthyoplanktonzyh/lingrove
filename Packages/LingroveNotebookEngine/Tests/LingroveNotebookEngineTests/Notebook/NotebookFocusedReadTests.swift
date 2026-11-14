import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Real private databases verify local editor/question/search boundaries independently of UI.
/// Poisoned unrelated records make accidental complete preparation observable, not just timed.
@MainActor struct NotebookFocusedReadTests {
    private func document() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<3).map { number in
            VocabularyEntry(id: UUID(), expression: "word\(number)", dictionaryForm: "lemma\(number)", language: .english,
                kind: .expression, senses: [.init(id: UUID(), meaning: "meaning\(number)", createdAt: now, updatedAt: now,
                    createdWithoutContext: true)], createdAt: now, updatedAt: now)
        }
        return .init(entries: entries)
    }
    private func seed(_ fixture: NotebookMediaDatabaseFixture, _ document: VocabularyDocument) throws -> LingroveNotebookSnapshot {
        try fixture.db.saveLingroveNotebook(document, basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
    }

    @Test func detailEditorChecksRawClockAndPreservesUnrelatedOwners() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = document(); _ = try seed(f, original); try f.reopen()
        let detail = try f.db.notebookEntryDetail(entryID: original.entries[0].id)
        var edited = try #require(detail.entry); edited.senses[0].note = "Local editor"
        let saved = try f.db.saveNotebookEntry(edited, basedOn: detail)
        #expect(saved.entry?.senses[0].note == "Local editor")
        #expect(f.db.core.notebookSaveCache == nil)
        #expect(try f.db.notebookEntryDetail(entryID: original.entries[1].id).entry == original.entries[1])
        #expect(throws: VocabularyError.editConflict) { try f.db.saveNotebookEntry(edited, basedOn: detail) }
        try f.db.core.execute(sql: "UPDATE notebook_collections SET payload_json=json_set(payload_json,'$.note','External') WHERE workspace_id=? AND sense_id=?",
            values: [.text(f.workspace), .text(edited.senses[0].id.uuidString)])
        #expect(throws: VocabularyError.editConflict) { try f.db.saveNotebookEntry(edited, basedOn: saved) }
    }

    @Test func detailEditorFallbackAndLateFailureAreAtomic() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        _ = try seed(f, document()); try f.reopen()
        let first = try #require(f.db.browseNotebook().entries.first)
        let detail = try f.db.notebookEntryDetail(entryID: first.id)
        var entry = try #require(detail.entry); entry.senses[0].note = "Must roll back"
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER reject_local_editor BEFORE INSERT ON notebook_pending_transactions
            BEGIN SELECT RAISE(ABORT,'Synthetic failure'); END;
            """, errorContext: "Protect atomic editing")
        #expect(throws: (any Error).self) { try f.db.saveNotebookEntry(entry, basedOn: detail) }
        #expect(try f.db.notebookEntryDetail(entryID: first.id).entry == detail.entry)
        #expect(try f.db.notebookBrowseFence() == detail.fence)
    }

    @Test func uncertifiedEditorUsesCheckedFullFallback() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = document(); _ = try seed(f, doc); try f.reopen()
        try f.db.core.execute(sql: "DELETE FROM notebook_entry_checkpoint", values: [])
        let detail = try f.db.notebookEntryDetail(entryID: doc.entries[0].id)
        var edited = try #require(detail.entry); edited.senses[0].note = "Fallback saved"
        let saved = try f.db.saveNotebookEntry(edited, basedOn: detail)
        #expect(saved.entry?.senses[0].note == "Fallback saved")
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace).document.entries.count == 3)
    }

    @Test func batchOwnerLookupHasOneFenceAndRejectsStaleVersions() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = document(), scope = try seed(f, doc); try f.reopen()
        let keys = Set(doc.entries.prefix(2).map(VocabularyIdentityPolicy.entryKey))
        let result = try f.db.notebookEntries(lookupKeys: keys, expected: .init(scope))
        #expect(Set(result.entries.map(\.id)) == Set(doc.entries.prefix(2).map(\.id)))
        #expect(f.db.core.notebookSaveCache == nil)
        let detail = try f.db.notebookEntryDetail(entryID: doc.entries[0].id)
        var next = try #require(detail.entry); next.senses[0].note = "Changed"
        _ = try f.db.saveNotebookEntry(next, basedOn: detail)
        #expect(throws: VocabularyError.editConflict) { try f.db.notebookEntries(lookupKeys: keys, expected: .init(scope)) }
    }

    @Test func literalSemanticJoinsMatchConfirmedSharedProjection() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let entries = document().entries
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Shared concept", language: .english)], definition: "Shared definition")
        let cue = VocabularyRetrievalCue(text: "retrieval phrase")
        let graph = VocabularySemanticIndex(nodes: [node], patterns: [.init(senseID: entries[0].senses[0].id, template: "pattern phrase")],
            mappings: [.init(nodeID: node.id, senseID: entries[0].senses[0].id, conditions: "condition phrase"),
                       .init(nodeID: node.id, senseID: entries[1].senses[0].id),
                       .init(nodeID: node.id, senseID: entries[2].senses[0].id, provenance: .init(status: .proposed))],
            cues: [cue], cueTargets: [.init(cueID: cue.id, nodeID: node.id)])
        _ = try seed(f, .init(entries: entries, semantics: graph)); try f.reopen()
        let material = try f.db.notebookLiteralSearchMaterial()
        for query in ["concept", "definition", "retrieval phrase", "pattern phrase", "condition phrase", "meaning0", "word2", "missing"] {
            let linked = Set(VocabularyMeaningBrowserProjection.items(index: graph, entries: entries, query: query,
                includeEmpty: false).flatMap(\.selections).map(\.senseID))
            let expected = Set(entries.flatMap { entry -> [UUID] in
                let direct = entry.senses.filter { sense in
                    var one = entry; one.senses = [sense]; return VocabularyNotebookQuery.matches(one, query: query)
                }
                return (direct.isEmpty ? entry.senses.filter { linked.contains($0.id) } : direct).map(\.id)
            })
            #expect(Set(try material.results(matching: query).entries.flatMap(\.senses).map(\.id)) == expected, "Semantic search: \(query)")
        }
    }

    @Test func questionReadsOnlyItsNoteAndPinsStyleWithoutChangingHistory() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = document(), scope = try seed(f, doc)
        _ = try f.db.enrollReviewNotes(selections: doc.entries.map { .init(entryID: $0.id, senseID: $0.senses[0].id) },
            type: ReviewNoteDefaults.type, scope: scope)
        let all = try f.db.loadLingroveNotebookReviewSnapshot(scope: scope)
        let card = try #require(all.noteCards.first { $0.value.note.senseID == doc.entries[0].senses[0].id })
        try f.reopen()
        try f.db.core.execute(sql: "UPDATE notebook_entries SET payload_json='{}' WHERE workspace_id=? AND id=?",
            values: [.text(f.workspace),.text(doc.entries[1].id.uuidString)])
        let question = try #require(try f.db.notebookReviewQuestion(cardID: card.key, workspaceID: f.workspace))
        #expect(question.rendered.backHTML.contains("meaning0"))
        #expect(try question.questionVersion == card.value.questionVersion(in: scope))
        #expect(f.db.core.notebookSaveCache == nil)
        var style = question.model.noteType; style.revision += 1; style.css += "\np{font-size:22px}"
        try f.db.saveReviewNoteType(style, expected: question.model.noteType, scope: scope)
        let updated = try #require(try f.db.notebookReviewQuestion(cardID: card.key, workspaceID: f.workspace))
        #expect(try updated.questionVersion != question.questionVersion)
        #expect(updated.review != question.review && updated.fence == question.fence)
        #expect(try f.db.notebookReviewQuestion(cardID: "ordinary-card", workspaceID: f.workspace) == nil)
        #expect(throws: VocabularyError.editConflict) { try f.db.notebookReviewQuestion(cardID: card.key, workspaceID: "another-owner") }
        #expect(try f.db.loadReviewEventCount() == 0)
    }

    @Test func literalFieldsMatchSharedProjectionAndDoNotEstablishWriterProof() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        var doc = document(); var entries = doc.entries
        entries[0].senses[0].note = "Café 中文"
        entries[0].senses[0].tags = ["search-tag"]
        entries[0].senses[0].content = [.init(content: .text(.init(text: "Formatted body")))]
        entries[0].senses[0].examples = [.init(id: UUID(), sourceKind: .authored, text: "Evidence source text", translation: "Translation needle",
            translationVariants: [.init(text: "Variant needle", language: .english)], ranges: [], completeness: .sentence, meaning: "Example meaning", createdAt: Date())]
        doc = .init(entries: entries)
        _ = try seed(f, doc); try f.reopen()
        let before = try f.db.notebookChanges()
        let material = try f.db.notebookLiteralSearchMaterial(locale: "en_US")
        for query in ["cafe", "中文", "search-tag", "Formatted", "Evidence", "Translation", "Variant", "Example meaning", "lemma0 cafe", "missing"] {
            let result = try material.results(matching: query)
            let expected = Set(doc.entries.filter { VocabularyNotebookQuery.matches($0, query: query) }.map(\.id))
            #expect(Set(result.entries.map(\.id)) == expected, "Search parity: \(query)")
            #expect(try result.page(limit: 1).total == expected.count)
        }
        #expect(f.db.core.notebookSaveCache == nil)
        #expect(try f.db.notebookChanges().stamp == before.stamp)
    }
}
