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
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved,
            selection: .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
        let enrollment = try #require(try f.engine.enrollNotebookSenses([draft], basedOn: saved).first)
        let exercise = try #require(try f.engine.lingroveNotebookReviewStore.exercises(enrollment).first)
        let storage = NotebookEngineStorage(engine: f.engine)
        let binding = try storage.capture(scope: f.scope)
        let request = try await storage.request(binding)
        let canonical = try JSONDecoder().decode(LingroveNotebookReviewRequest.self, from: request.body)
        #expect(request.hasWork && !canonical.enrollments.isEmpty && !canonical.operations.isEmpty)
        _ = try f.engine.submitNotebookRating(.init(cardId: exercise.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), basedOn: saved)
        let sentIDs = canonical.enrollments.map(\.operationId) + canonical.links.map(\.operationId)
            + canonical.operations.compactMap { op -> String? in
                guard case let .object(fields) = op.operation, case let .string(id)? = fields["operationId"] else { return nil }
                return id
            } + canonical.undos.map(\.undoId) + canonical.historyAdoptions.map(\.operationId)
        let response = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1,
            "notebookId": f.scope.notebookID.uuidString, "replicaId": f.scope.replicaID.uuidString,
            "acknowledged": sentIDs, "confirmed": [], "afterSequence": canonical.afterSequence,
            "hasMore": false, "changes": []] as [String: Any])
        #expect(try await storage.apply(response, request: request, binding: binding) == false)
        let next = try await storage.request(binding)
        #expect(next.hasWork)
        let pending = try JSONDecoder().decode(LingroveNotebookReviewRequest.self, from: next.body)
        #expect(pending.operations.count == 2, "The later rating and event were never sent in this ACK")
        #expect(try f.engine.loadActiveCard(workspaceId: f.workspace, cardId: exercise.cardId).reps == 1)
        try f.engine.close()
        let reopened = try LingroveNotebookEngine(databaseURL: f.database, mediaDirectoryURL: f.media)
        defer { try? reopened.close() }
        let restored = try await NotebookEngineStorage(engine: reopened).request(binding)
        #expect(restored.body == next.body)
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
