import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookSync
import Testing
@testable import LingroveNotebookCloud

/// These ports execute the actual engine and its canonical review codec against disposable files.
/// HTTP/PG is verified separately through the mobile caller using this same bridge and runner.
@MainActor
struct EngineCloudIntegrationTests {
    @Test func existingMobileGuestKeepsItsStoredAuthorizationKind() throws {
        let f = try EngineCloudFixture(); defer { f.cleanUp() }
        try f.engine.updateCloudSettings(cloudState: .guest, linkedUserId: f.owner,
            linkedWorkspaceId: f.workspace, activeWorkspaceId: f.workspace, linkedEmail: nil)
        let storage = NotebookEngineStorage(engine: f.engine)
        _ = try storage.installation(for: .init(userID: f.owner, workspaceID: f.scope.workspaceID,
            apiBaseURL: "https://api.example.invalid/v1", authorizationHeaderValue: "Guest synthetic",
            isAutomation: true, isTestDistribution: true, isGuest: true))
        #expect(try f.engine.core.scalarText(sql: "SELECT scope_kind FROM notebook_account_scopes WHERE workspace_id=?",
            values: [.text(f.workspace)]) == "guest")
        #expect(try f.engine.workspaceSettingsStore.loadCloudSettings().cloudState == .guest)
    }

    @Test func exactReviewAckRetainsLaterRatingAcrossReopen() async throws {
        let f = try EngineCloudFixture(); defer { f.cleanUp() }
        let saved = try f.engine.saveLingroveNotebook(Self.document(),
            basedOn: f.engine.loadLingroveNotebook(workspaceId: f.workspace))
        let selection = VocabularySelection(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id)
        _ = try f.engine.enrollReviewNotes(selections: [selection], type: ReviewNoteDefaults.type, scope: saved)
        let content = try f.engine.loadBuiltInNotebookReview(scope: saved, now: Date())
        let card = try #require(content.queue.first)
        let storage = NotebookEngineStorage(engine: f.engine)
        let binding = try storage.capture(scope: f.scope)
        let request = try await storage.request(binding)
        let canonical = try JSONDecoder().decode(LingroveNotebookReviewRequest.self, from: request.body)
        #expect(request.hasWork && !canonical.enrollments.isEmpty && !canonical.operations.isEmpty)
        _ = try f.engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selection))
        let sentIDs = canonical.enrollments.map(\.operationId) + canonical.links.map(\.operationId)
            + canonical.operations.compactMap { op -> String? in
                guard case let .object(fields) = op.operation, case let .string(id)? = fields["operationId"] else { return nil }
                return id
            } + canonical.undos.map(\.undoId) + canonical.historyAdoptions.map(\.operationId)
        let response = try JSONSerialization.data(withJSONObject: ["protocolVersion": 3,
            "noteState": try JSONSerialization.jsonObject(with: JSONEncoder().encode(canonical.noteState)),
            "acknowledgedNoteState": try #require(canonical.noteStateDigest),
            "notebookId": f.scope.notebookID.uuidString, "replicaId": f.scope.replicaID.uuidString,
            "acknowledged": sentIDs, "confirmed": [], "afterSequence": canonical.afterSequence,
            "hasMore": false, "changes": []] as [String: Any])
        #expect(try await storage.apply(response, request: request, binding: binding) == false)
        let next = try await storage.request(binding)
        #expect(next.hasWork)
        let pending = try JSONDecoder().decode(LingroveNotebookReviewRequest.self, from: next.body)
        #expect(pending.operations.count == 2, "The later rating and event were never sent in this ACK")
        #expect(try f.engine.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId).reps == 1)
        try f.engine.close()
        let reopened = try LingroveNotebookEngine(databaseURL: f.database, mediaDirectoryURL: f.media)
        defer { try? reopened.close() }
        let restored = try await NotebookEngineStorage(engine: reopened).request(binding)
        #expect(restored.body == next.body)
    }

    @Test func pendingMaterialMediaRemainsWorkUntilExactVersion3Acknowledgment() async throws {
        let f = try EngineCloudFixture(); defer { f.cleanUp() }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let image = VocabularyImageReference(digest: ReviewMaterialMediaReference.digest(bytes), width: 1, height: 1,
            byteCount: bytes.count)
        let reference = ReviewMaterialMediaReference(image: image)
        let prepared = ReviewMaterialPreparedMedia(reference: reference, data: bytes)
        var document = Self.document()
        document.entries[0].senses[0].content = [.init(content: .image(image, caption: "Synthetic Note media"))]
        let saved = try f.engine.saveLingroveNotebook(document, basedOn: f.engine.loadLingroveNotebook(workspaceId: f.workspace),
            images: [image.filename: bytes])
        let entry = saved.document.entries[0]
        _ = try f.engine.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: entry.senses[0].id)],
            type: ReviewNoteDefaults.type, scope: saved)
        let storage = NotebookEngineStorage(engine: f.engine), binding = try storage.capture(scope: f.scope)
        let request = try await storage.request(binding)
        let canonical = try JSONDecoder().decode(LingroveNotebookReviewRequest.self, from: request.body)
        #expect(request.hasWork && canonical.protocolVersion == 3 && canonical.media == [prepared])
        #expect(canonical.enrollments.isEmpty && canonical.links.isEmpty && canonical.operations.isEmpty)
        func reply(version: Int, digests: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": version,
                "noteState": try JSONSerialization.jsonObject(with: JSONEncoder().encode(canonical.noteState)),
                "acknowledgedNoteState": try #require(canonical.noteStateDigest),
                "notebookId": f.scope.notebookID.uuidString, "replicaId": f.scope.replicaID.uuidString,
                "acknowledged": [], "acknowledgedMedia": digests, "confirmed": [], "afterSequence": canonical.afterSequence,
                "hasMore": false, "changes": []] as [String: Any])
        }
        await #expect(throws: (any Error).self) { try await storage.apply(reply(version: 1, digests: []), request: request, binding: binding) }
        #expect(try await storage.request(binding).body == request.body)
        _ = try await storage.apply(reply(version: 3, digests: [reference.digest]), request: request, binding: binding)
        let next = try await storage.request(binding)
        let nextCanonical = try JSONDecoder().decode(LingroveNotebookReviewRequest.self, from: next.body)
        #expect(next.hasWork && nextCanonical.media == nil && nextCanonical.noteState?.notes.count == 1)
    }

    @Test func retiredBindingsAndClosedOriginalConnectionCannotWriteThroughPorts() async throws {
        let f = try EngineCloudFixture(); defer { f.cleanUp() }
        let saved = try f.engine.saveLingroveNotebook(Self.document(),
            basedOn: f.engine.loadLingroveNotebook(workspaceId: f.workspace))
        let storage = NotebookEngineStorage(engine: f.engine)
        let old = try storage.capture(scope: f.scope)
        try f.engine.updateCloudSettings(cloudState: .linked, linkedUserId: "other-synthetic-owner",
            linkedWorkspaceId: f.workspace, activeWorkspaceId: f.workspace, linkedEmail: nil)
        try f.engine.updateCloudSettings(cloudState: .linked, linkedUserId: f.owner,
            linkedWorkspaceId: f.workspace, activeWorkspaceId: f.workspace, linkedEmail: nil)
        await #expect(throws: NotebookStorageError.bindingChanged) { try await storage.request(old) }
        await #expect(throws: NotebookStorageError.bindingChanged) {
            try await storage.enqueue([], direction: .upload, consumer: "late", binding: old)
        }
        #expect(try f.engine.loadLingroveNotebook(workspaceId: f.workspace).revision == saved.revision)
        let fresh = try storage.capture(scope: f.scope)
        try f.engine.close()
        await #expect(throws: LocalStoreError.self) { try await storage.initial(fresh) }
    }

    private static func document() -> VocabularyDocument {
        let date = Date()
        return VocabularyDocument(entries: [.init(id: UUID(), expression: "synthetic", dictionaryForm: "synthetic",
            language: .english, kind: .word, senses: [.init(id: UUID(), meaning: "test meaning",
                meaningLanguage: .english, meaningOrigin: .user, isSavedWithoutContext: true,
                createdAt: date, updatedAt: date)], createdAt: date, updatedAt: date)])
    }
}

/// The host supplies both locations and a synthetic linked scope. Nothing discovers or mutates
/// an installed application's directory, settings, accounts, network or Keychain.
@MainActor
private final class EngineCloudFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-cloud-" + UUID().uuidString)
    let owner = "engine-cloud-owner"
    let engine: LingroveNotebookEngine
    let workspace: String
    let database: URL
    let media: URL
    let scope: VocabularyWireWindowScope
    init() throws {
        database = directory.appendingPathComponent("primary.sqlite")
        media = directory.appendingPathComponent("media", isDirectory: true)
        engine = try LingroveNotebookEngine(databaseURL: database, mediaDirectoryURL: media)
        workspace = try engine.workspaceSettingsStore.loadWorkspace().workspaceId
        try engine.updateCloudSettings(cloudState: .linked, linkedUserId: owner,
            linkedWorkspaceId: workspace, activeWorkspaceId: workspace, linkedEmail: nil)
        scope = .init(ownerUserID: owner, workspaceID: try #require(UUID(uuidString: workspace)),
            notebookID: UUID(), replicaID: UUID())
    }
    func cleanUp() { try? engine.close(); try? FileManager.default.removeItem(at: directory) }
}
