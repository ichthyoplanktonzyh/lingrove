import Foundation
import LingroveNotebookSync

/// The notebook lane owns an ephemeral session with no cookies/cache. It sends
/// only typed metadata or exact persisted public bytes, reads bounded replies,
/// and never reports corpus bodies to the legacy sync/analytics transport.
@MainActor
public struct NotebookHTTPTransport {
    private nonisolated let http: BoundedHTTPClient

    public init(session: URLSession? = nil) { http = BoundedHTTPClient(session: session) }

    public func capabilities(_ account: NotebookAccount) async throws -> VocabularyWireCapabilities {
        try await request(account, path: "capabilities", limit: 12_288, stagedFeature: true)
    }

    /// Canonical review encoding/decoding belongs to storage, keeping Card/FSRS out of transport.
    public func review(_ value: NotebookReviewRequest, account: NotebookAccount) async throws -> Data {
        try await response(account, path: "review/sync", body: value.body, limit: 8 * 1024 * 1024)
    }

    public func connect(_ account: NotebookAccount, installationID: UUID) async throws -> VocabularyWireConnection {
        let body = try json(["protocolVersion":1,"installationId":installationID.uuidString.lowercased(),
            "isAutomation":account.isAutomation,"isTestDistribution":account.isTestDistribution])
        let connection: VocabularyWireConnection = try await request(account, path: "connect", body: body, limit: 8192)
        guard connection.ownerUserID.utf8.elementsEqual(account.userId.utf8), connection.workspaceID == UUID(uuidString: account.workspaceId) else {
            throw NotebookNetworkError.identityMismatch
        }
        return connection
    }

    /// Endpoint selection is part of this API: a caller cannot accidentally
    /// resend apply while the persisted batch says cancellation was requested.
    public func settle(_ pending: NotebookPendingUpload, account: NotebookAccount) async throws -> VocabularyWireGroupOutcome {
        guard pending.batch.transport == .direct, pending.batch.scope.workspaceID == UUID(uuidString: account.workspaceId),
              pending.batch.scope.ownerUserID.utf8.elementsEqual(account.userId.utf8) else { throw NotebookNetworkError.identityMismatch }
        if let known = pending.outcome { return known }
        let outcome: VocabularyWireGroupOutcome = try await request(account, path: pending.cancelRequested ? "groups/cancel" : "groups/apply",
            body: pending.body, limit: 512 * 1024)
        try outcome.validate(for: pending.batch)
        return outcome
    }

    public func openWindow(_ account: NotebookAccount, scope: VocabularyWireWindowScope, after: VocabularyWireSequence?) async throws -> VocabularyWireWindowManifest {
        try checkScope(scope, account: account)
        let body = try json(["protocolVersion":1,"notebookId":scope.notebookID.uuidString.lowercased(),"replicaId":scope.replicaID.uuidString.lowercased(),
            "mode":after == nil ? "bootstrap" : "incremental","afterSequence":after.map { $0.rawValue as Any } ?? NSNull()])
        let manifest: VocabularyWireWindowManifest = try await request(account, path: "windows/open", body: body, limit: 8192)
        try manifest.validate(expecting: scope, now: Date())
        guard manifest.afterSequence == after else { throw NotebookNetworkError.invalidReply }
        return manifest
    }

    public func page(_ ordinal: Int, manifest: VocabularyWireWindowManifest, account: NotebookAccount) async throws -> VocabularyWireWindowPage {
        try checkScope(manifest.scope, account: account)
        var fields = identity(manifest); fields["ordinal"] = ordinal
        return try await request(account, path: "windows/page", body: json(fields), limit: 400 * 1024)
    }

    public func release(_ manifest: VocabularyWireWindowManifest, account: NotebookAccount) async throws {
        try checkScope(manifest.scope, account: account)
        let response: VocabularyWireJSON = try await request(account, path: "windows/release", body: json(identity(manifest)), limit: 4096)
        guard response == .object(["released":.bool(true)]) else { throw NotebookNetworkError.invalidReply }
    }

    /// Staged methods preserve the explicit resumable protocol used by the shared runner.
    /// They reuse the same bounded, redirect-fenced authenticated session; the
    /// caller still fences account generations after each suspension point.
    public func openStaged(_ upload: VocabularyWireStagedUpload, account: NotebookAccount) async throws -> VocabularyWireStagedManifest {
        try checkScope(upload, account: account)
        let manifest: VocabularyWireStagedManifest = try await request(account, path: "uploads/open", body: upload.declarationBody(), limit: 16_384)
        try manifest.validate(for: upload, now: Date()); return manifest
    }
    public func stagedStatus(_ upload: VocabularyWireStagedUpload, account: NotebookAccount) async throws -> VocabularyWireStagedManifest {
        try checkScope(upload, account: account)
        let manifest: VocabularyWireStagedManifest = try await request(account, path: "uploads/status", body: upload.identityBody(), limit: 16_384)
        try manifest.validate(for: upload, now: Date()); return manifest
    }
    public func sendStagedChunk(_ ordinal: Int, upload: VocabularyWireStagedUpload, progress: VocabularyWireStagedManifest,
                         account: NotebookAccount) async throws -> VocabularyWireStagedManifest {
        try checkScope(upload, account: account); try progress.validate(for: upload, now: Date())
        guard progress.state == .open else { throw VocabularyWireStagedError.invalidManifest }
        let body = try await Self.chunkBody(ordinal, upload: upload)
        let manifest: VocabularyWireStagedManifest = try await request(account, path: "uploads/chunk", body: body, limit: 16_384)
        try manifest.validate(for: upload, now: Date()); return manifest
    }
    public func abortStaged(_ upload: VocabularyWireStagedUpload, account: NotebookAccount) async throws -> VocabularyWireStagedManifest {
        try checkScope(upload, account: account)
        let manifest: VocabularyWireStagedManifest = try await request(account, path: "uploads/abort", body: upload.identityBody(), limit: 16_384)
        try manifest.validate(for: upload, now: Date()); return manifest
    }
    public func finalizeStaged(_ upload: VocabularyWireStagedUpload, progress: VocabularyWireStagedManifest,
                        account: NotebookAccount) async throws -> VocabularyWireConfirmationManifest {
        try checkScope(upload, account: account); try progress.validate(for: upload, now: Date())
        if progress.state == .finalized { return try await stagedConfirmation(upload, account: account) }
        guard progress.state == .open, progress.receivedOrdinals.count == upload.chunkCount else { throw VocabularyWireStagedError.invalidManifest }
        let manifest: VocabularyWireConfirmationManifest = try await request(account, path: "uploads/finalize", body: upload.identityBody(), limit: 16_384)
        try manifest.validate(for: upload); return manifest
    }
    public func stagedConfirmation(_ upload: VocabularyWireStagedUpload, account: NotebookAccount) async throws -> VocabularyWireConfirmationManifest {
        try checkScope(upload, account: account)
        let manifest: VocabularyWireConfirmationManifest = try await request(account, path: "uploads/confirmation", body: upload.identityBody(), limit: 16_384)
        try manifest.validate(for: upload); return manifest
    }
    public func stagedConfirmationPage(_ ordinal: Int, manifest: VocabularyWireConfirmationManifest, upload: VocabularyWireStagedUpload,
                                account: NotebookAccount) async throws -> VocabularyWireConfirmationPage {
        try checkScope(upload, account: account)
        return try await request(account, path: "uploads/confirmation-page", body: upload.confirmationPageBody(ordinal, manifest: manifest), limit: 256 * 1024)
    }
    private func checkScope(_ scope: VocabularyWireWindowScope, account: NotebookAccount) throws {
        guard scope.workspaceID == UUID(uuidString: account.workspaceId),
              scope.ownerUserID.utf8.elementsEqual(account.userId.utf8) else { throw NotebookNetworkError.identityMismatch }
    }
    private func checkScope(_ upload: VocabularyWireStagedUpload, account: NotebookAccount) throws {
        guard upload.batch.scope.workspaceID == UUID(uuidString: account.workspaceId),
              upload.batch.scope.ownerUserID.utf8.elementsEqual(account.userId.utf8) else { throw NotebookNetworkError.identityMismatch }
    }
    @concurrent private nonisolated static func chunkBody(_ ordinal: Int, upload: VocabularyWireStagedUpload) async throws -> Data {
        try Task.checkCancellation()
        return try upload.chunkBody(ordinal)
    }

    private func identity(_ manifest: VocabularyWireWindowManifest) -> [String: Any] {
        ["notebookId":manifest.scope.notebookID.uuidString.lowercased(),"replicaId":manifest.scope.replicaID.uuidString.lowercased(),
         "windowId":manifest.windowID.uuidString.lowercased(),"manifestSha256":manifest.manifestSHA256]
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }

    private nonisolated func endpoint(_ account: NotebookAccount, path: String) throws -> URL {
        guard let workspace = UUID(uuidString: account.workspaceId),
              let safe = try? AccountConfigurationPolicy.baseURL(account.apiBaseUrl),
              var url = URLComponents(url: safe, resolvingAgainstBaseURL: false) else {
            throw NotebookNetworkError.invalidEndpoint
        }
        while url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath.removeLast() }
        url.percentEncodedPath += "/workspaces/" + workspace.uuidString.lowercased() + "/notebook/" + path
        guard let result = url.url else { throw NotebookNetworkError.invalidEndpoint }; return result
    }

    @concurrent private nonisolated func request<T: Decodable & Sendable>(_ account: NotebookAccount, path: String, body: Data? = nil, limit: Int, stagedFeature: Bool = false) async throws -> T {
        let data = try await response(account, path: path, body: body, limit: limit, stagedFeature: stagedFeature)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @concurrent private nonisolated func response(_ account: NotebookAccount, path: String, body: Data? = nil, limit: Int, stagedFeature: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: try endpoint(account, path: path))
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(account.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let platform = account.nativePlatform {
            request.setValue(platform.rawValue, forHTTPHeaderField: "X-Client-Platform")
        }
        if stagedFeature { request.setValue("staged-upload-v1", forHTTPHeaderField: "X-Lingrove-Corpus-Features") }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await http.response(for: request, maximumBytes: limit, errorMaximumBytes: 8192, acceptedStatusCodes: 200..<201) }
        catch BoundedHTTPError.responseTooLarge { throw NotebookNetworkError.replyTooLarge }
        catch BoundedHTTPError.invalidResponse { throw NotebookNetworkError.invalidReply }
        guard response.statusCode == 200 else {
            // Only a bounded machine code is retained. Proxy HTML, arbitrary
            // server messages and linguistic payloads never become log context.
            let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let raw = fields?["code"] as? String
            let code = raw.flatMap { value in value.utf8.count <= 96 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 } ? value : nil }
            throw NotebookNetworkError.http(status: response.statusCode, code: code)
        }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "application/json" else { throw NotebookNetworkError.invalidReply }
        return data
    }
}

