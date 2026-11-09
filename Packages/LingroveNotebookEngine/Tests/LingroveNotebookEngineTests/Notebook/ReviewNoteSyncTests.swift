import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookEngine

@MainActor
struct ReviewNoteSyncTests {
    @Test func acknowledgementKeepsEditsMadeDuringFlightAndRejectsOldProtocol() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let scope = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let entry = try #require(scope.document.entries.first)
        _ = try f.db.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: entry.senses[0].id)],
            type: ReviewNoteDefaults.type, scope: scope)
        let store = ReviewNoteStore(core: f.db.core), sync = LingroveNotebookReviewSyncStore(core: f.db.core)
        let binding = try f.binding(), request = try sync.request(f.binding())
        let sent = try #require(request.noteState)
        #expect(request.protocolVersion == 3)
        #expect(try request.noteStateDigest == sent.digest())
        var edited = ReviewNoteDefaults.type; edited.revision += 1; edited.css += "\n.card{padding:32px}"
        try f.db.saveReviewNoteType(edited, expected: ReviewNoteDefaults.type, scope: scope)
        let old = LingroveNotebookReviewResponse(protocolVersion: 1, notebookId: request.notebookId,
            replicaId: request.replicaId, acknowledged: [], confirmed: [], afterSequence: request.afterSequence, hasMore: false, changes: [])
        #expect(throws: (any Error).self) { try sync.apply(old, request: request, binding: binding) }
        let ack = request.enrollments.map(\.operationId) + request.links.map(\.operationId) + request.operations.compactMap { item -> String? in
            guard case let .object(fields) = item.operation, case let .string(id)? = fields["operationId"] else { return nil }; return id
        }
        let response = LingroveNotebookReviewResponse(protocolVersion: 3, notebookId: request.notebookId,
            replicaId: request.replicaId, acknowledged: ack, confirmed: [], afterSequence: request.afterSequence,
            hasMore: false, changes: [], noteState: sent, acknowledgedNoteState: try sent.digest())
        try sync.apply(response, request: request, binding: binding)
        #expect(try store.types(workspace: f.workspace).first?.css == edited.css)
        #expect(try store.hasPendingSync(scope: scope))
        #expect(try sync.request(binding).noteBase == sent)
        try f.reopen()
        #expect(try ReviewNoteStore(core: f.db.core).hasPendingSync(scope: scope))
    }

    @Test func concurrentDefinitionConflictRollsBackEveryDefinition() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let scope = try f.db.loadLingroveNotebook(workspaceId: f.workspace), store = ReviewNoteStore(core: f.db.core)
        let initial = ReviewNoteSyncState(types: [ReviewNoteDefaults.type], notes: [], memberships: [], defaultTypeID: ReviewNoteDefaults.type.id)
        var local = ReviewNoteDefaults.type; local.revision = 2; local.css = "local"
        try f.db.saveReviewNoteType(local, expected: ReviewNoteDefaults.type, scope: scope)
        var remote = local; remote.css = "remote"
        var extra = local; extra.id = UUID(); extra.revision = 1
        let state = ReviewNoteSyncState(types: [extra, remote], notes: [], memberships: [], defaultTypeID: local.id)
        #expect(throws: (any Error).self) {
            try f.db.core.inTransaction { try store.applySyncState(state, sent: initial, scope: scope) }
        }
        #expect(try store.types(workspace: f.workspace) == [local])
    }

    @Test func sourceChangeGeneratesNewConditionalCardAndDisabledTemplateKeepsHistory() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        var document = LingroveNotebookReviewCompletionTests.document()
        document.entries[0].senses[0].note = ""
        let scope = try f.db.saveLingroveNotebook(document, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        var type = ReviewNoteDefaults.type; type.id = UUID()
        type.templates.append(.init(name: "Optional", front: "{{#Notes}}{{Notes}}{{/Notes}}", back: "{{Meaning}}"))
        try f.db.saveReviewNoteType(type, expected: nil, scope: scope)
        let selection = VocabularySelection(entryID: document.entries[0].id, senseID: document.entries[0].senses[0].id)
        _ = try f.db.enrollReviewNotes(selections: [selection], type: type, scope: scope)
        #expect(try f.db.loadBuiltInNotebookReview(scope: scope, now: Date()).noteCards.count == 1)
        document.entries[0].senses[0].note = "Now present"
        let updated = try f.db.saveLingroveNotebook(document, basedOn: scope)
        let before = try f.db.loadBuiltInNotebookReview(scope: updated, now: Date())
        #expect(before.queue.count == 2)
        let card = try #require(before.queue.first)
        _ = try f.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: before, selection: selection))
        var disabled = type; disabled.revision += 1
        disabled.templates = disabled.templates.map { var t = $0; t.enabled = false; return t }
        try f.db.saveReviewNoteType(disabled, expected: type, scope: updated)
        let after = try f.db.loadBuiltInNotebookReview(scope: updated, now: Date())
        #expect(after.queue.isEmpty && after.noteCards.count == 2)
        #expect(after.review.groups[selection.senseID]?.hasUnavailableMaterial == false)
        #expect(after.statistics.ratingRecords == 1)
    }
}
