import Foundation
import LingroveCloud
import Testing
@testable import Lingrove

/// Held SDK callbacks intentionally ignore task cancellation, as an already delivered URLSession
/// callback can. Both a recovery waiter and its authorization must lose the original generation
/// before another account's credentials become visible through the same long-lived facade.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct AccountAuthorizationRaceTests {
    @Test func authorizationAndIdentityWaitersRejectLogoutReloginDuringSharedRecovery() async throws {
        let f = try AccountTestFixture(); defer { f.cleanup() }
        try await f.signIn()
        f.client.holdRefresh = true
        let oldAuthorization = Task { try await f.service.authorization(forceRefresh: true) }
        try await accountEventually { f.client.refreshReply != nil }
        let oldIdentity = Task { try await f.service.confirmedIdentity(forceRefresh: true) }
        await Task.yield()
        let oldGeneration = f.service.observation.generation
        f.service.signOut()
        f.client.currentIdentity = .init(userID: "second-account", email: "second@example.invalid", canonicalAccountID: nil)
        f.client.holdRefresh = false
        try await f.signIn()
        f.client.refreshReply?.resume(returning: AccountTestClient.rotated)
        f.client.refreshReply = nil
        await #expect(throws: AccountIssue.cancelled) { try await oldAuthorization.value }
        await #expect(throws: AccountIssue.cancelled) { try await oldIdentity.value }
        let current = try await f.service.authorization()
        #expect(current.identity.userID == "second-account" && current.idToken == AccountTestClient.tokens.idToken)
        #expect(current.generation != oldGeneration)
        #expect(f.credentials.value?.identity?.userID == "second-account")
    }

    @Test func authorizationRejectsServiceReplacementWhileIdentityCheckIsSuspended() async throws {
        let f = try AccountTestFixture(); defer { f.cleanup() }
        try await f.signIn()
        f.client.holdIdentity = true
        let old = Task { try await f.service.authorization(forceRefresh: true) }
        try await accountEventually { f.client.identityReply != nil }
        f.service.configure(api: "https://different.example.invalid/v1", auth: "https://different.example.invalid/auth")
        f.client.identityReply?.resume(returning: f.client.currentIdentity)
        f.client.identityReply = nil
        await #expect(throws: AccountIssue.cancelled) { try await old.value }
        #expect(f.service.state == .signedOut && f.credentials.value == nil)
    }
}
