import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookSync
import Testing
@testable import Lingrove

/// These are integration journeys across real private Keychain, URLSession and the single SQL
/// repository. They assert committed data and task revocation, rather than mirroring controller
/// branches or pretending the synthetic peer establishes production cloud/provider readiness.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct MacNotebookSyncControllerTests {
    @Test func lateMetadataCannotReplaceOfflineStatus() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        f.start(); try await f.signIn()
        let count = try await f.server.stats().paths.filter { $0 == "/api/workspaces" }.count
        try await f.server.mode("delay-workspaces")
        f.sync.refreshWorkspaces()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await f.server.stats().paths.filter({ $0 == "/api/workspaces" }).count == count {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await f.server.mode("me-offline")
        _ = try? await f.account.confirmedIdentity(recheck: true)
        try await Task.sleep(for: .milliseconds(700))
        #expect(f.sync.workspaceStatus == .offline && !f.sync.canAccessWorkspaces)
        #expect(!f.sync.isLoadingWorkspaces)
    }

    @Test func loginDoesNotSelectAdoptOrUploadAndRetainCanLaterBeExplicitlyAccepted() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        let original = try f.saveLocal(withReview: true)
        f.start()
        #expect(try await f.server.stats().paths.isEmpty)
        try await f.signIn()
        #expect(f.sync.selectedWorkspace == nil && !f.sync.enabled)
        #expect(try f.repository.snapshot().workspaceId == original.workspaceId)
        #expect(try await f.server.stats().paths.allSatisfy { !$0.contains("notebook/") && !$0.contains("sync/bootstrap") })
        try await f.connect()
        let linked = try f.repository.snapshot()
        #expect(linked.document.catalog.isEmpty && f.sync.ownershipProposal?.status == "pending")
        let fsrs = try f.repository.engine.workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: linked.workspaceId)
        #expect(fsrs.desiredRetention == 0.87 && fsrs.learningStepsMinutes == [2, 12] && !fsrs.enableFuzz)
        f.sync.setSynchronizationEnabled(true)
        #expect(!f.sync.enabled)
        f.sync.resolveLocalCorpus(accept: false)
        #expect(f.sync.ownershipProposal?.status == "separate")
        #expect(try f.repository.snapshot().document.catalog.isEmpty)
        #expect(try f.repository.engine.loadLingroveNotebook(workspaceId: original.workspaceId).document == original.document)
        let staleChoice = try #require(f.sync.ownershipProposal)
        f.sync.cancel()
        f.sync.resolveLocalCorpus(accept: true, expected: staleChoice)
        #expect(f.sync.corpusStatus == .conflict)
        #expect(try f.repository.snapshot().document.catalog.isEmpty)
        f.sync.resolveLocalCorpus(accept: true)
        #expect(f.sync.ownershipProposal?.status == "merged")
        let adopted = try f.repository.snapshot()
        #expect(adopted.document.catalog.count == 1)
        let enrollments = try f.repository.engine.loadLingroveNotebookReviewEnrollments(workspaceId: adopted.workspaceId)
        #expect(enrollments.count == 1)
        let exercise = try #require(try f.repository.engine.lingroveNotebookReviewStore.exercises(enrollments[0]).first)
        #expect(try f.repository.engine.loadActiveCard(workspaceId: adopted.workspaceId, cardId: exercise.cardId).reps == 1)
        #expect(try f.repository.engine.loadReviewEvents(workspaceId: adopted.workspaceId).count == 1)
        #expect(try await f.server.stats().groups == 0)
        try await f.server.mode("review-unavailable")
        f.sync.setSynchronizationEnabled(true)
        try await syncEventually { f.sync.corpusStatus == .synchronized && f.sync.reviewStatus == .unavailable }
        #expect(f.sync.mediaStatus == .synchronized)
        let stats = try await f.server.stats()
        #expect(stats.groups > 0 && stats.images == 1 && stats.checks.allSatisfy { $0 })
        try await f.server.mode("expire-token")
        f.sync.retry()
        try await syncEventually { f.sync.reviewStatus == .synchronized }
        #expect(try await f.server.stats().refreshes == 1)
        try await f.server.mode("scheduler-updated")
        f.sync.retry()
        try await syncEventually { f.sync.corpusStatus == .synchronized }
        #expect(try f.repository.engine.workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: adopted.workspaceId).desiredRetention == 0.93)
        try await f.server.mode("offline")
        f.sync.retry()
        try await syncEventually { f.sync.corpusStatus == .offline }
        #expect(try f.repository.snapshot().document.catalog.count == 1)
        try await f.server.mode("normal")
        f.sync.retry()
        try await syncEventually { f.sync.corpusStatus == .synchronized && f.sync.reviewStatus == .synchronized }
        try await f.server.mode("me-offline")
        _ = try? await f.account.confirmedIdentity(recheck: true)
        #expect(f.sync.corpusStatus == .offline && !f.sync.canAccessWorkspaces)
        try await f.server.mode("normal")
        f.sync.retry()
        try await syncEventually { f.sync.corpusStatus == .synchronized && f.sync.canAccessWorkspaces }
        try f.restart()
        try await syncEventually { f.sync.enabled && f.sync.corpusStatus == .synchronized }
        #expect(try f.repository.snapshot().document.catalog.count == 1)
        #expect(try f.repository.engine.loadReviewEvents(workspaceId: adopted.workspaceId).count == 1)
        #expect(try f.repository.engine.workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: adopted.workspaceId).desiredRetention == 0.93)
        f.sync.cancel()
        let cancelledGeneration = try f.repository.snapshot().generation
        #expect(!f.sync.enabled && f.sync.corpusStatus == .cancelled)
        try f.restart()
        try await syncEventually { f.sync.selectedWorkspace != nil }
        #expect(!f.sync.enabled)
        #expect(try f.repository.snapshot().generation != cancelledGeneration)
    }

    @Test func switchingAccountsIsolatesOldContentAndLateBindingsAcrossReopen() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        let source = try f.saveLocal()
        f.start(); try await f.signIn(); try await f.connect()
        f.sync.resolveLocalCorpus(accept: true)
        let accountA = try f.repository.snapshot()
        let oldBinding = try f.repository.cloudStorage.capture(scope: .init(ownerUserID: "business-owner-a",
            workspaceID: try #require(UUID(uuidString: accountA.workspaceId)), notebookID: UUID(), replicaID: UUID()))
        try await f.server.mode("delay-caps")
        f.sync.setSynchronizationEnabled(true)
        try await f.server.waitForRequest(suffix: "/notebook/capabilities")
        f.account.signOut()
        #expect(try f.repository.snapshot().workspaceId != accountA.workspaceId)
        #expect(try f.repository.snapshot().document.catalog.isEmpty)
        #expect(throws: NotebookStorageError.bindingChanged) { try f.repository.cloudStorage.validate(oldBinding) }
        #expect(throws: VocabularyError.self) { try f.repository.engine.saveLingroveNotebook(accountA.document, basedOn: accountA) }
        try await f.server.mode("normal")
        try await f.signIn("b"); try await f.connect()
        let accountB = try f.repository.snapshot()
        #expect(accountB.document.catalog.isEmpty && f.sync.ownershipProposal == nil)
        #expect(try f.repository.engine.loadLingroveNotebook(workspaceId: accountA.workspaceId).document.catalog.count == 1)
        #expect(try f.repository.engine.loadLingroveNotebook(workspaceId: source.workspaceId).document.catalog.count == 1)
        try await Task.sleep(for: .milliseconds(700))
        #expect(try f.repository.snapshot().workspaceId == accountB.workspaceId)
        #expect(try f.repository.snapshot().document.catalog.isEmpty)
        f.account.signOut(); try f.restart()
        #expect(try f.repository.snapshot().document.catalog.isEmpty)
        try await f.signIn("a")
        try await syncEventually { f.sync.selectedWorkspace?.id == accountA.workspaceId }
        #expect(try f.repository.snapshot().document.catalog.count == 1)
        #expect(try await f.server.stats().checks.allSatisfy { $0 })
    }

    @Test func switchingWorkspaceRetiresThePreviousCloudChoiceAndSignOutStaysSignedOut() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        var stage = "login"
        var complete = false
        defer {
            if !complete {
                print("Synthetic workspace stage=\(stage), corpus=\(f.sync.corpusStatus), workspace=\(f.sync.workspaceStatus), scheduler=\(f.sync.schedulerStatus), first=\(f.sync.firstConnection != nil)")
                print("Synthetic first rows=\((try? f.repository.engine.core.scalarInt(sql: "SELECT count(*) FROM notebook_first_connections", values: [])) ?? -1)")
            }
        }
        f.start(); try await f.signIn(); try await f.connect()
        try f.saveLocal()
        try await f.server.mode("initialized-empty")
        f.sync.setSynchronizationEnabled(true)
        stage = "first cloud choice"
        try await syncEventually { f.sync.firstConnection != nil }
        let original = try #require(f.sync.firstConnection)
        let next = try #require(f.sync.workspaces.first { $0.id != f.sync.selectedWorkspace?.id })
        stage = "second workspace"
        f.sync.chooseWorkspace(next.id)
        try await syncEventually { !f.sync.isChoosingWorkspace && f.sync.selectedWorkspace?.id == next.id }
        #expect(f.sync.firstConnection == nil && !f.sync.enabled)
        #expect(try f.repository.snapshot().workspaceId != original.original.workspaceId)
        f.sync.resolveFirstConnection(combine: false, expected: original)
        #expect(try f.repository.snapshot().workspaceId == next.id)
        #expect(try f.repository.engine.core.scalarText(sql: "SELECT decision FROM notebook_first_connections WHERE recovery_id=?", values: [.text(original.id)]) == "pending")
        f.account.signOut()
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.account.state == .signedOut)
        #expect(f.sync.selectedWorkspace == nil && f.sync.workspaces.isEmpty)
        complete = true
    }

    @Test func offlineCredentialRefreshRetiresWorkspaceSelectionAndAllowsAnotherChoice() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        f.start(); try await f.signIn(); try await f.connect()
        let original = try f.repository.snapshot()
        let next = try #require(f.sync.workspaces.first { $0.id != original.workspaceId })
        try await f.server.mode("scheduler-unauthorized")
        f.sync.chooseWorkspace(next.id)
        try await syncEventually {
            if case .offline = f.account.state { return !f.sync.isChoosingWorkspace }; return false
        }
        #expect(!f.sync.canAccessWorkspaces && f.sync.workspaceStatus == .offline)
        #expect(try f.repository.snapshot().workspaceId == original.workspaceId)
        try await f.server.mode("normal")
        f.sync.retry()
        try await syncEventually { f.sync.canAccessWorkspaces }
        f.sync.chooseWorkspace(next.id)
        try await syncEventually { !f.sync.isChoosingWorkspace && f.sync.selectedWorkspace?.id == next.id }
        #expect(!f.sync.enabled)
    }

    @Test func tokenRefreshDuringSelectionCannotRestartThePreviousWorkspaceFlight() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        f.start(); try await f.signIn(); try await f.connect()
        f.sync.setSynchronizationEnabled(true)
        try await syncEventually { f.sync.corpusStatus == .synchronized }
        let before = try await f.server.stats().paths.filter { $0.hasSuffix("/notebook/capabilities") }.count
        let next = try #require(f.sync.workspaces.first { $0.id != f.sync.selectedWorkspace?.id })
        try await f.server.mode("scheduler-token-expired")
        f.sync.chooseWorkspace(next.id)
        try await syncEventually { !f.sync.isChoosingWorkspace && f.sync.selectedWorkspace?.id == next.id }
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await f.server.stats().refreshes == 1)
        #expect(try await f.server.stats().paths.filter { $0.hasSuffix("/notebook/capabilities") }.count == before)
        #expect(try f.repository.snapshot().workspaceId == next.id)
        #expect(!f.sync.enabled)
    }

    @Test func invalidCredentialsIsolateDataAndRemoveEveryOldAccountControl() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        f.start(); try await f.signIn(); try await f.connect()
        let saved = try f.saveLocal()
        f.sync.setSynchronizationEnabled(true)
        try await syncEventually { f.sync.corpusStatus == .synchronized }
        try await f.server.mode("token-invalid")
        _ = try? await f.account.authorization(forceRefresh: true)
        #expect(f.account.state == .credentialsInvalid)
        #expect(f.sync.selectedWorkspace == nil && f.sync.workspaces.isEmpty && !f.sync.enabled)
        #expect(f.sync.ownershipProposal == nil && f.sync.firstConnection == nil && !f.sync.isChoosingWorkspace)
        #expect(!f.sync.canAccessWorkspaces)
        #expect(try f.repository.snapshot().workspaceId != saved.workspaceId)
        #expect(try f.repository.snapshot().document.catalog.isEmpty)
        #expect(try f.repository.engine.loadLingroveNotebook(workspaceId: saved.workspaceId).document.catalog.count == 1)
    }

    @Test func metadataIdentityCannotBorrowAnotherWorkspaceAndCollectionDoesNotEnroll() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        f.start(); try await f.signIn()
        let authorization = try await f.account.authorization()
        try await f.server.mode("wrong-owner")
        await #expect(throws: AccountWorkspaceError.identityChanged) {
            try await AccountWorkspaceClient().metadata(authorization: authorization)
        }
        try await f.server.mode("normal")
        f.sync.chooseWorkspace("99999999-0000-0000-0000-000000000000")
        #expect(f.sync.selectedWorkspace == nil)
        try await f.connect()
        let saved = try f.saveLocal()
        #expect(try f.repository.engine.loadLingroveNotebookReviewEnrollments(workspaceId: saved.workspaceId).isEmpty)
        #expect(!f.sync.enabled)
    }
}
