import Foundation
import LingroveNotebook
import LingroveNotebookSync
import Testing
@testable import LingroveNotebookEngine

/// The Mac facade is exercised directly against files, never a mobile store or service graph.
/// Every fixture owns a disposable connection and synthetic account identity.
@MainActor
struct EngineScopedCommandIntegrationTests {
    @Test("Metadata reads preserve generation fences without decoding or accepting invalid corpus content")
    func notebookVersionSeparatesAdmissionFromContentValidation() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        #expect(try f.db.currentNotebookVersion() == LingroveNotebookVersion(saved))
        try f.db.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil,
            linkedWorkspaceId: nil, activeWorkspaceId: f.workspace, linkedEmail: nil)
        let version = try #require(try f.db.currentNotebookVersion())
        #expect(version.revision == saved.revision && version.notebookId == saved.notebookId)
        #expect(!version.hasSameOwner(as: saved))
        let current = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        try f.db.core.execute(sql: "UPDATE notebook_senses SET payload_json='invalid-json' WHERE workspace_id=?",
            values: [.text(f.workspace)])
        #expect(try f.db.currentNotebookVersion() == version)
        #expect(throws: (any Error).self) { try f.db.loadLingroveNotebook(workspaceId: f.workspace) }
        #expect(throws: (any Error).self) { try f.db.saveLingroveNotebook(current.document, basedOn: current) }
        #expect(try f.db.currentNotebookVersion() == version)
    }

    @Test("A saved screen cannot enroll, rate or replay participation after an account ABA switch")
    func scopedCommandsRejectRetiredGeneration() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved,
            selection: .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
        let enrolled = try f.db.enrollNotebookSenses([draft], basedOn: saved)
        let cardID = try #require(try f.db.lingroveNotebookReviewStore.exercises(enrolled[0]).first).cardId
        let pauseID = UUID()
        let paused = try f.db.setNotebookReviewStatus(.paused, enrollments: enrolled, basedOn: saved, requestID: pauseID)
        _ = try f.db.setNotebookReviewStatus(.active, enrollments: paused, basedOn: saved)
        try f.db.updateCloudSettings(cloudState: .linked, linkedUserId: "another-synthetic-owner",
            linkedWorkspaceId: f.workspace, activeWorkspaceId: f.workspace, linkedEmail: nil)
        try f.db.updateCloudSettings(cloudState: .linked, linkedUserId: f.owner,
            linkedWorkspaceId: f.workspace, activeWorkspaceId: f.workspace, linkedEmail: nil)
        let before = try counts(f.db)
        #expect(throws: VocabularyError.self) { try f.db.enrollNotebookSenses([draft], basedOn: saved) }
        #expect(throws: VocabularyError.self) {
            try f.db.setNotebookReviewStatus(.paused, enrollments: enrolled, basedOn: saved, requestID: pauseID)
        }
        #expect(throws: VocabularyError.self) {
            try f.db.submitNotebookRating(.init(cardId: cardID, rating: .good,
                reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), basedOn: saved)
        }
        #expect(try counts(f.db) == before)
        let fresh = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        let rated = try f.db.submitNotebookRating(.init(cardId: cardID, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), basedOn: fresh)
        #expect(rated.reps == 1)
        #expect(throws: CancellationError.self) {
            try f.db.undoLastNotebookRating(workspaceId: f.workspace, cardId: cardID, generation: saved.generation)
        }
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: cardID).reps == 1)
        try f.db.undoLastNotebookRating(workspaceId: f.workspace, cardId: cardID, generation: fresh.generation)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: cardID).reps == 0)
    }

    @Test("Cancelled corpus and rating commands leave their SQLite journals unchanged")
    func cancellationDoesNotPublish() async throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved,
            selection: .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
        let enrollment = try #require(try f.db.enrollNotebookSenses([draft], basedOn: saved).first)
        let cardID = try #require(try f.db.lingroveNotebookReviewStore.exercises(enrollment).first).cardId
        let before = try counts(f.db)
        let cancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var rejected = 0
            do { _ = try f.db.saveLingroveNotebook(saved.document, basedOn: saved) }
            catch is CancellationError { rejected += 1 }
            catch { Issue.record(error) }
            do {
                _ = try f.db.submitNotebookRating(.init(cardId: cardID, rating: .good,
                    reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), basedOn: saved)
            } catch is CancellationError { rejected += 1 }
            catch { Issue.record(error) }
            return rejected
        }.value
        #expect(cancelled == 2)
        #expect(try counts(f.db) == before)
    }

    @Test("Media persistence uses its injected directory and survives a fresh connection")
    func independentMediaDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engine-media-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sql/notebook.sqlite")
        let mediaURL = directory.appendingPathComponent("blobs", isDirectory: true)
        var engine = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaURL)
        let workspace = try engine.workspaceSettingsStore.loadWorkspace().workspaceId
        let png = try LingroveNotebookMediaQueueIntegrationTests.image()
        let saved = try engine.saveLingroveNotebook(LingroveNotebookMediaQueueIntegrationTests.document(png.reference),
            basedOn: engine.loadLingroveNotebook(workspaceId: workspace), images: [png.reference.filename: png.data])
        let relative = try mediaBlobCacheRelativePath(sha256: png.reference.digest)
        #expect(FileManager.default.fileExists(atPath: mediaURL.appendingPathComponent(relative).path))
        #expect(!FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().appendingPathComponent(relative).path))
        try engine.close()
        engine = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaURL)
        defer { try? engine.close() }
        #expect(try engine.loadLingroveNotebook(workspaceId: workspace) == saved)
        #expect(try LingroveNotebookMediaStore(core: engine.core).image(png.reference, scope: saved) == png.data)
    }

    @Test("Linking offers ownership, while explicit acceptance copies only selected review and finite history")
    func explicitAccountAcceptance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engine-adoption-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try LingroveNotebookEngine(databaseURL: directory.appendingPathComponent("notebook.sqlite"), mediaDirectoryURL: directory)
        defer { try? engine.close() }
        let source = try engine.workspaceSettingsStore.loadWorkspace().workspaceId
        let saved = try engine.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: engine.loadLingroveNotebook(workspaceId: source))
        _ = try engine.enrollReviewNotes(selections: [.init(entryID: saved.document.entries[0].id,
            senseID: saved.document.entries[0].senses[0].id)], type: ReviewNoteDefaults.type, scope: saved)
        let oldCard = try #require(try ReviewNoteStore(core: engine.core).memberships(workspace: source).first).cardID
        _ = try engine.submitNotebookRating(.init(cardId: oldCard, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), basedOn: saved)
        let target = UUID().uuidString.lowercased()
        let account = CloudLinkedSession(userId: "synthetic-engine-owner", workspaceId: target, email: nil,
            configurationMode: .custom, apiBaseUrl: "http://127.0.0.1:19080", authorization: .bearer("synthetic-unused"))
        #expect(try engine.preserveNotebookWorkspaceForLink(source: source, account: account))
        let owners = LingroveNotebookAccountStore(core: engine.core)
        #expect(try engine.loadLingroveNotebook(workspaceId: target).document.entries.isEmpty)
        #expect(try engine.loadLingroveNotebookReviewEnrollments(workspaceId: target).isEmpty)
        let proposal = try #require(try owners.proposal(workspaceID: target))
        let accepted = try owners.resolve(proposal, merge: true)
        #expect(accepted.document.entries.count == saved.document.entries.count)
        #expect(try engine.loadLingroveNotebookReviewEnrollments(workspaceId: target).count == 1)
        #expect(try engine.cardStore.loadReviewEvents(workspaceId: target).count == 1)
        #expect(try engine.cardStore.loadReviewEvents(workspaceId: source).count == 1)
        let adoptions = try engine.core.query(sql: "SELECT payload_json FROM notebook_review_history_adoptions WHERE workspace_id=?",
            values: [.text(target)]) { DatabaseCore.columnText(statement: $0, index: 0) }
        let adoption = try JSONDecoder().decode(LingroveNotebookReviewRequest.HistoryAdoption.self, from: Data(try #require(adoptions.first).utf8))
        #expect(adoption.eventIds.count == 1)
        #expect(adoption.originWorkspaceId == source)
        let copiedNotes = try ReviewNoteStore(core: engine.core).cardModels(scope: accepted)
        #expect(copiedNotes.count == 1 && copiedNotes[adoption.cardId] != nil)
        #expect(try copiedNotes[adoption.cardId]?.render(in: accepted).backHTML.contains(saved.document.entries[0].senses[0].meaning) == true)
        #expect(adoption.cardId != oldCard)
        #expect(try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM pragma_foreign_key_check", values: []) == 0)
    }

    @Test("Review exact ACK retires the sent prefix while retaining a later rating and the corpus cursor")
    func exactReviewAcknowledgement() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved,
            selection: .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
        let enrollment = try #require(try f.db.enrollNotebookSenses([draft], basedOn: saved).first)
        let cardID = try #require(try f.db.lingroveNotebookReviewStore.exercises(enrollment).first).cardId
        let sync = LingroveNotebookReviewSyncStore(core: f.db.core), binding = try f.binding()
        let request = try sync.request(binding)
        let after = try f.db.submitNotebookRating(.init(cardId: cardID, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), basedOn: saved)
        let sent = request.enrollments.map(\.operationId) + request.links.map(\.operationId) + request.operations.compactMap { op -> String? in
            guard case let .object(fields) = op.operation, case let .string(id)? = fields["operationId"] else { return nil }
            return id
        } + request.undos.map(\.undoId) + request.historyAdoptions.map(\.operationId)
        let response = LingroveNotebookReviewResponse(protocolVersion: request.protocolVersion,
            notebookId: request.notebookId, replicaId: request.replicaId, acknowledged: sent,
            confirmed: [], afterSequence: request.afterSequence, hasMore: false, changes: [],
            noteState: request.noteState, acknowledgedNoteState: request.noteStateDigest)
        try sync.apply(response, request: request, binding: binding)
        let next = try sync.request(binding)
        #expect(next.operations.count == 2)
        #expect(next.enrollments.allSatisfy { !Set(sent).contains($0.operationId) })
        #expect(next.links.allSatisfy { !Set(sent).contains($0.operationId) })
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: cardID) == after)
        #expect(try f.db.lingroveNotebookSyncStore.confirmedShadow(binding: binding) == nil)
    }

    @Test("Closing a borrowed facade preserves the host connection; host close fences all borrowers")
    func borrowedLifetime() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let borrowed = try LingroveNotebookEngine(borrowing: f.db.core)
        try borrowed.close()
        #expect(try f.db.core.scalarInt(sql: "SELECT 1", values: []) == 1)
        try f.db.close()
        #expect(throws: LocalStoreError.self) { try borrowed.loadLingroveNotebook(workspaceId: f.workspace) }
    }

    @Test("A canonically equivalent authored spelling survives later generated material refresh")
    func literalManualOwnership() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let now = Date()
        let sense = VocabularySense(id: UUID(), meaning: "cafe\u{0301}", meaningLanguage: .english,
            meaningOrigin: .user, isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        let document = VocabularyDocument(entries: [.init(id: UUID(), expression: "coffee", dictionaryForm: "coffee",
            language: .english, kind: .word, senses: [sense], createdAt: now, updatedAt: now)])
        let saved = try f.db.saveLingroveNotebook(document, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved,
            selection: .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
        let selected = try #require(try f.db.enrollNotebookSenses([draft], basedOn: saved).first)
        let cardID = try #require(try f.db.lingroveNotebookReviewStore.exercises(selected).first).cardId
        var card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: cardID)
        let authored = card.backText.precomposedStringWithCanonicalMapping
        #expect(!authored.utf8.elementsEqual(card.backText.utf8))
        _ = try f.db.saveCard(workspaceId: f.workspace, input: .init(frontText: card.frontText,
            backText: authored, tags: card.tags), cardId: cardID, mediaAssetIdsReadyForUpload: [])
        var changed = saved.document
        changed.entries[0].senses[0].meaning = "new generated answer"
        _ = try f.db.saveLingroveNotebook(changed, basedOn: saved, restoringBackup: true)
        card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: cardID)
        #expect(card.backText.utf8.elementsEqual(authored.utf8))
        #expect(card.reps == 0)
    }

    @Test("Generated Unicode spelling and its baseline advance together across repeated source edits")
    func generatedCanonicalSpellingRemainsSourceOwned() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let now = Date()
        let sense = VocabularySense(id: UUID(), meaning: "caf\u{00e9}", meaningLanguage: .english,
            meaningOrigin: .user, isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        let doc = VocabularyDocument(entries: [.init(id: UUID(), expression: "coffee", dictionaryForm: "coffee",
            language: .english, kind: .word, senses: [sense], createdAt: now, updatedAt: now)])
        var saved = try f.db.saveLingroveNotebook(doc, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved,
            selection: .init(entryID: saved.document.entries[0].id, senseID: sense.id))
        let enrollment = try #require(try f.db.enrollNotebookSenses([draft], basedOn: saved).first)
        let exercise = try #require(try f.db.lingroveNotebookReviewStore.exercises(enrollment).first)
        for meaning in ["cafe\u{0301}", "caf\u{00e9} updated"] {
            var changed = saved.document
            changed.entries[0].senses[0].meaning = meaning
            saved = try f.db.saveLingroveNotebook(changed, basedOn: saved, restoringBackup: true)
            let card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: exercise.cardId)
            let link = try #require(try f.db.lingroveNotebookCardLinkStore.find(workspaceId: f.workspace, id: exercise.linkId))
            #expect(card.backText.utf8.elementsEqual(try #require(link.generatedContent).backText.utf8))
            #expect(card.backText.contains(meaning) && card.reps == 0)
        }
    }

    private func counts(_ engine: LingroveNotebookEngine) throws -> [Int] {
        try ["cards", "review_events", "notebook_pending_transactions", "notebook_pending_rows",
            "notebook_review_operations", "notebook_card_link_operations", "notebook_held_card_operations",
            "notebook_review_requests"].map { try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM \($0)", values: []) }
    }
}
