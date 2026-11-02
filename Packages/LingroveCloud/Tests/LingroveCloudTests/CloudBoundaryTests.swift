import Foundation
import LingroveCloud
import LingroveNotebookSync
import Testing

/// Real sockets plus typed recording stores cover the extraction seam. These scenarios neither
/// claim PostgreSQL/provider acceptance nor replace the repository's SQLite/FSRS suites.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct CloudBoundaryTests {
    @Test func otpRefreshAndTrustedMeUseBoundedRedirectFencedHTTP() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let client = AccountAPIClient(), config = try peer.configuration
        let sent = try await client.sendCode(email: "synthetic@example.invalid", configuration: config)
        guard case .challenge(let challenge) = sent else { Issue.record("Expected native OTP"); return }
        await #expect(throws: AccountIssue.invalidCode) { try await client.verifyCode("00000000", challenge: challenge, configuration: config) }
        let credentials = try await client.verifyCode("12345678", challenge: challenge, configuration: config)
        let identity = try await client.identity(idToken: credentials.idToken, configuration: config)
        #expect(identity.userID == "server-owner" && identity.userID != credentials.idToken)
        let refreshed = try await client.refresh(credentials, configuration: config)
        #expect(refreshed.refreshToken == "rotated-refresh")
        for prefix in ["redirect", "oversized", "streamed"] {
            await #expect(throws: AccountIssue.invalidResponse) {
                try await client.sendCode(email: prefix + "@example.invalid", configuration: config)
            }
        }
        #expect(try await peer.stats().leaks == 0)
    }

    @Test func sharedRefreshPersistsRotationBeforeOfflineIdentityAndFencesLogout() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = RecordingAccountStore(), config = try peer.configuration
        store.record = .init(configuration: config, allowsSessionRestore: true)
        store.session = .init(configuration: config, credentials: .init(idToken: "old-id", refreshToken: "old-refresh", expiresAt: .distantPast),
            identity: .init(userID: "server-owner", email: nil, canonicalAccountID: nil))
        let service = AccountSession(client: AccountAPIClient(), credentials: store, settings: store)
        defer { service.shutdown() }
        try await peer.mode("me-unavailable")
        let a = Task { try await service.confirmedIdentity(forceRefresh: true) }
        let b = Task { try await service.confirmedIdentity(forceRefresh: true) }
        _ = await a.result; _ = await b.result
        #expect(try await peer.stats().refreshes == 1)
        #expect(store.session?.credentials.refreshToken == "rotated-refresh")
        #expect(store.writes.count == 1)
        #expect(service.state == .offline(store.session?.identity))
        try await peer.mode("delay-refresh")
        let delayed = Task { try await service.confirmedIdentity(forceRefresh: true) }
        try await eventually { try await peer.stats().refreshes == 2 }
        service.signOut()
        let count = store.writes.count
        _ = await delayed.result
        #expect(store.session == nil && store.writes.count == count && service.state == .signedOut)
        #expect(store.record?.allowsSessionRestore == false)
    }

    @Test func cancelledConsumerDoesNotCancelSharedRefreshAndConnectionClearFailureRetainsScope() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = RecordingAccountStore(), config = try peer.configuration
        store.record = .init(configuration: config, allowsSessionRestore: true)
        store.session = .init(configuration: config, credentials: .init(idToken: "old", refreshToken: "old", expiresAt: .distantPast), identity: nil)
        let service = AccountSession(client: AccountAPIClient(), credentials: store, settings: store)
        defer { service.shutdown() }
        try await peer.mode("delay-refresh")
        let a = Task { try await service.confirmedIdentity(forceRefresh: true) }
        try await eventually { try await peer.stats().refreshes == 1 }
        let b = Task { try await service.confirmedIdentity(forceRefresh: true) }
        a.cancel()
        #expect(try await b.value.userID == "server-owner")
        _ = await a.result
        #expect(try await peer.stats().refreshes == 1)
        store.failClear = true
        #expect(!service.configure(api: peer.origin + "/other-api", auth: peer.origin + "/other-auth"))
        #expect(service.configuration == config && service.issue == .secureStorage)
        #expect(!AccountConfigurationPolicy.matchesSavedConnection(api: peer.origin + "/other-api", auth: peer.origin + "/other-auth", saved: service.configuration))
        #expect(store.record?.allowsSessionRestore == false)
    }

    @Test func directCorpusExactAckRetainsLaterIntentAndPinsMediaUntilApply() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook()
        store.localOperations.insert("later")
        store.references = [CloudFixture.image]
        let runner = NotebookNetworkRunner(storage: store, mediaStorage: store)
        let result = try await runner.synchronize(peer.account)
        #expect(result.state.revision == 2 && result.state.pendingCount == 1)
        #expect(store.localOperations == ["later"])
        #expect(store.images[CloudFixture.image.filename] == CloudFixture.png)
        let events = store.ledger.events
        #expect(try #require(events.firstIndex(of: "outcome")) < #require(events.firstIndex(of: "apply")))
        #expect(try #require(events.firstIndex(of: "media-complete")) < #require(events.firstIndex(of: "apply")))
        #expect(try #require(events.firstIndex(of: "apply")) < #require(events.firstIndex(where: { $0.hasPrefix("unpin:window:") })))
        let paths = try await peer.stats().paths
        #expect(paths.filter { $0.hasSuffix("windows/open") }.count == 2)
    }

    @Test func stagedChunksAndPagedConfirmationPreserveFrozenIdentity() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook(staged: true)
        let frozen = try #require(store.pending).frozenSHA256
        let result = try await NotebookNetworkRunner(storage: store, mediaStorage: store).synchronize(peer.account)
        #expect(result.state.pendingCount == 0)
        #expect(store.pending == nil)
        #expect(frozen.count == 64)
        #expect(store.ledger.events.contains("confirmation") && store.ledger.events.contains("confirmation-page"))
        let paths = try await peer.stats().paths
        #expect(paths.filter { $0.hasSuffix("uploads/chunk") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("uploads/finalize") }.count == 1)
        #expect(!paths.contains(where: { $0.hasSuffix("groups/apply") }))
    }

    @Test func stagedCancelClosesTransportWithoutAcknowledgingLocalIntent() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook(staged: true); store.cancelAtControl = true
        _ = try await NotebookNetworkRunner(storage: store, mediaStorage: store).synchronize(peer.account)
        #expect(store.pending?.stagedClosure?.reason == .aborted)
        #expect(store.localOperations == ["sent"])
        #expect(store.ledger.events.contains("closure"))
        #expect(!(try await peer.stats().paths).contains(where: { $0.hasSuffix("uploads/chunk") || $0.hasSuffix("uploads/finalize") }))
    }

    @Test func unexpectedAckNeverReachesStorageAndMediaTransportRoundTripsPNG() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook()
        try await peer.mode("bad-ack")
        await #expect(throws: VocabularyWireUploadError.receiptMismatch) {
            try await NotebookNetworkRunner(storage: store, mediaStorage: store).synchronize(peer.account)
        }
        #expect(!store.ledger.events.contains("outcome") && store.localOperations == ["sent"])
        try await peer.mode("normal")
        let media = NotebookMediaTransport(), binding = NotebookBinding(scope: CloudFixture.scope, generation: store.generation)
        try await media.capabilities(peer.account, binding: binding)
        let uploaded = try await media.upload(CloudFixture.png, reference: CloudFixture.image, account: peer.account, binding: binding)
        #expect(uploaded.state == "ready")
        #expect(try await media.download(CloudFixture.image, account: peer.account, binding: binding) == CloudFixture.png)
        try await media.release(CloudFixture.image, account: peer.account, binding: binding)
    }

    @Test func independentReviewFailureRetainsCorpusRevisionAndSingleFlight() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook()
        let coordinator = NotebookSyncCoordinator(storage: store, mediaStorage: store, reviewStorage: store)
        try await peer.mode("review-fails")
        let a = Task { try await coordinator.synchronize(peer.account) }
        let b = Task { try await coordinator.synchronize(peer.account) }
        let first = try await a.value, joined = try await b.value
        #expect(first == joined && first.status == .synchronized && first.revision == 2)
        #expect(first.reviewStatus == .unavailable && first.reviewRevision == 0)
        #expect(store.reviewOperations == ["00000000-0000-0000-0000-000000000005"] && store.localOperations.isEmpty)
        #expect((try await peer.stats().paths).filter { $0.hasSuffix("groups/apply") }.count == 1)
        try await peer.mode("normal")
        coordinator.requestRetry()
        let recovered = try await coordinator.synchronize(peer.account)
        #expect(recovered.reviewStatus == .synchronized && recovered.reviewRevision == 7)
        #expect(store.reviewOperations.isEmpty)
    }

    @Test func backoffAndGenerationRetirementBlockWritesAfterRealHTTPWait() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook()
        let coordinator = NotebookSyncCoordinator(storage: store, mediaStorage: store, reviewStorage: store)
        try await peer.mode("caps-unavailable")
        let unavailable = try await coordinator.synchronize(peer.account)
        #expect(unavailable.status == .unavailable)
        _ = try await coordinator.synchronize(peer.account)
        #expect((try await peer.stats().paths).filter { $0.hasSuffix("notebook/capabilities") }.count == 1)
        try await peer.mode("delay-caps")
        coordinator.requestRetry()
        let delayed = Task { try await coordinator.synchronize(peer.account) }
        try await eventually { try await peer.stats().paths.filter { $0.hasSuffix("notebook/capabilities") }.count == 2 }
        store.generation = "generation-two"
        let result = await delayed.result
        if case .success = result { Issue.record("Retired generation returned a report") }
        #expect(store.ledger.events.isEmpty && store.localOperations == ["sent"])
        #expect(!(try await peer.stats().paths).contains(where: { $0.hasSuffix("connect") }))
    }

    @Test func reviewAuthenticationFailurePropagatesAfterCorpusCommitAndLifecycleCancelRetiresWork() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook()
        let coordinator = NotebookSyncCoordinator(storage: store, mediaStorage: store, reviewStorage: store)
        try await peer.mode("review-401")
        await #expect(throws: NotebookNetworkError.http(status: 401, code: "UNAUTHORIZED")) {
            try await coordinator.synchronize(peer.account)
        }
        #expect(store.stateRevision == 2 && store.localOperations.isEmpty && store.reviewCursor == 0)
        #expect(store.reviewOperations == ["00000000-0000-0000-0000-000000000005"])
        let committed = store.ledger.events
        try await peer.mode("delay-caps")
        let delayed = Task { try await coordinator.synchronize(peer.account) }
        try await eventually { try await peer.stats().paths.filter { $0.hasSuffix("notebook/capabilities") }.count == 2 }
        coordinator.cancel()
        store.generation = "generation-two"
        if case .success = await delayed.result { Issue.record("Cancelled pass returned success") }
        #expect(store.ledger.events == committed)
    }

    @Test func readyMediaMappingsDoNotRequireANewUploadCapabilityProbe() async throws {
        let peer = try CloudLoopback(); defer { peer.stop() }
        let store = try RecordingNotebook()
        store.pending = try CloudFixture.upload(staged: false, withImage: true)
        store.readyUploads = true
        try await peer.mode("media-probe-fails")
        let result = try await NotebookNetworkRunner(storage: store, mediaStorage: store).synchronize(peer.account)
        #expect(result.state.pendingCount == 0)
        #expect(!(try await peer.stats().paths).contains(where: { $0.hasSuffix("media/capabilities") }))
    }

    private func eventually(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while try await !predicate() {
            if Date() > deadline { throw NotebookNetworkError.invalidReply }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
