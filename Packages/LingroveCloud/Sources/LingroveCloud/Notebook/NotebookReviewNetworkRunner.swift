import Foundation

/// One independent held review lane, invoked only after corpus/media settlement. Canonical wire
/// encoding and transactional response/ACK checks stay in the repository port. Sixteen bounded
/// pages preserve the mobile retry budget without rebuilding scheduler state from event history.
@MainActor
public struct NotebookReviewNetworkRunner {
    private let storage: any NotebookReviewStorage
    private let transport: NotebookHTTPTransport
    private let validate: @MainActor (NotebookBinding) throws -> Void
    public init(storage: any NotebookReviewStorage, transport: NotebookHTTPTransport = .init(),
                validate: @escaping @MainActor (NotebookBinding) throws -> Void) {
        self.storage = storage; self.transport = transport; self.validate = validate
    }
    public func synchronize(_ account: NotebookAccount, binding: NotebookBinding) async throws -> (revision: Int64, pending: Bool) {
        guard binding.scope.workspaceID == UUID(uuidString: account.workspaceId),
              binding.scope.ownerUserID.utf8.elementsEqual(account.userId.utf8) else { throw NotebookNetworkError.identityMismatch }
        for _ in 0..<16 {
            try check(binding)
            let request = try await storage.request(binding)
            try check(binding)
            let response = try await transport.review(request, account: account)
            try check(binding)
            let hasMore = try await storage.apply(response, request: request, binding: binding)
            try check(binding)
            let next = try await storage.request(binding)
            try check(binding)
            if !hasMore && !next.hasWork { return (next.afterSequence, false) }
        }
        let next = try await storage.request(binding)
        try check(binding)
        return (next.afterSequence, true)
    }
    private func check(_ binding: NotebookBinding) throws { try Task.checkCancellation(); try validate(binding) }
}
