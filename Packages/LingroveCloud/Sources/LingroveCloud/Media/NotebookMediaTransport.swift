import Foundation
import LingroveNotebook

/// The byte lane has its own bounded session and never uses Card's authoring
/// uploader or signed URLs in persistent state. Credentials remain on the
/// current notebook API origin; redirects, cookies and HTTP caching are denied.
nonisolated public struct NotebookMediaTransport: Sendable {
    private let http: BoundedHTTPClient
    private struct RequestBody: Encodable {
        let protocolVersion = 1
        let notebookId: UUID
        let replicaId: UUID
        let image: VocabularyImageReference
    }
    private struct Capabilities: Decodable {
        let protocolVersion: Int; let mimeType: String; let maximumBytes: Int; let maximumDimension: Int
    }
    public init(session: URLSession? = nil) { http = BoundedHTTPClient(session: session) }
    @concurrent public func capabilities(_ account: NotebookAccount, binding: NotebookBinding) async throws {
        let bytes = try await request(account, binding: binding, path: "capabilities", method: "GET", limit: 4096)
        let value = try JSONDecoder().decode(Capabilities.self, from: bytes)
        guard value.protocolVersion == 1, value.mimeType == "image/png", value.maximumBytes == 4 * 1024 * 1024,
              value.maximumDimension == 1600 else { throw NotebookMediaError.invalidDescriptor }
    }
    @concurrent public func metadata(_ reference: VocabularyImageReference, action: String,
                              account: NotebookAccount, binding: NotebookBinding) async throws -> NotebookMediaDescriptor {
        try validate(reference)
        guard ["prepare", "resolve"].contains(action) else { throw NotebookMediaError.invalidDescriptor }
        let body = try JSONEncoder().encode(RequestBody(notebookId: binding.scope.notebookID, replicaId: binding.scope.replicaID, image: reference))
        let bytes = try await request(account, binding: binding, path: action, method: "POST", body: body, limit: 8192)
        let descriptor = try JSONDecoder().decode(NotebookMediaDescriptor.self, from: bytes)
        try descriptor.validate(reference, binding: binding)
        return descriptor
    }
    @concurrent public func upload(_ bytes: Data, reference: VocabularyImageReference,
                            account: NotebookAccount, binding: NotebookBinding) async throws -> NotebookMediaDescriptor {
        try validate(reference)
        guard bytes.count == reference.byteCount, bytes.count <= 4 * 1024 * 1024 else { throw NotebookMediaError.invalidDescriptor }
        let data = try await request(account, binding: binding, path: "bytes", method: "PUT", body: bytes, image: reference, limit: 8192)
        let descriptor = try JSONDecoder().decode(NotebookMediaDescriptor.self, from: data)
        try descriptor.validate(reference, binding: binding)
        guard descriptor.state == "ready" else { throw NotebookMediaError.incomplete(.missing) }
        return descriptor
    }
    @concurrent public func download(_ reference: VocabularyImageReference, account: NotebookAccount,
                              binding: NotebookBinding) async throws -> Data {
        try validate(reference)
        return try await request(account, binding: binding, path: "bytes", method: "GET", image: reference, limit: reference.byteCount, pngReply: true)
    }
    @concurrent public func release(_ reference: VocabularyImageReference, account: NotebookAccount,
                             binding: NotebookBinding) async throws {
        try validate(reference)
        let body = try JSONEncoder().encode(RequestBody(notebookId: binding.scope.notebookID, replicaId: binding.scope.replicaID, image: reference))
        let bytes = try await request(account, binding: binding, path: "release", method: "POST", body: body, limit: 4096)
        guard (try JSONSerialization.jsonObject(with: bytes) as? [String: Bool]) == ["released": true] else {
            throw NotebookMediaError.invalidDescriptor
        }
    }
    private func validate(_ reference: VocabularyImageReference) throws {
        guard (1...4 * 1024 * 1024).contains(reference.byteCount), (1...1600).contains(reference.width),
              (1...1600).contains(reference.height), reference.digest.utf8.count == 64,
              reference.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NotebookMediaError.invalidDescriptor
        }
    }
    private func endpoint(_ account: NotebookAccount, binding: NotebookBinding, path: String,
                          image: VocabularyImageReference?) throws -> URL {
        guard binding.scope.workspaceID == UUID(uuidString: account.workspaceId),
              binding.scope.ownerUserID.utf8.elementsEqual(account.userId.utf8),
              let safe = try? AccountConfigurationPolicy.baseURL(account.apiBaseUrl),
              var url = URLComponents(url: safe, resolvingAgainstBaseURL: false) else {
            throw NotebookNetworkError.invalidEndpoint
        }
        while url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath.removeLast() }
        url.percentEncodedPath += "/workspaces/" + binding.scope.workspaceID.uuidString.lowercased() + "/notebook/media/" + path
        if let image {
            url.queryItems = [URLQueryItem(name: "protocolVersion", value: "1"),
                .init(name: "notebookId", value: binding.scope.notebookID.uuidString.lowercased()),
                .init(name: "replicaId", value: binding.scope.replicaID.uuidString.lowercased()),
                .init(name: "digest", value: image.digest), .init(name: "width", value: String(image.width)),
                .init(name: "height", value: String(image.height)), .init(name: "byteCount", value: String(image.byteCount))]
        }
        guard let result = url.url else { throw NotebookNetworkError.invalidEndpoint }
        return result
    }
    private func request(_ account: NotebookAccount, binding: NotebookBinding, path: String, method: String,
                         body: Data? = nil, image: VocabularyImageReference? = nil, limit: Int, pngReply: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: try endpoint(account, binding: binding, path: path, image: image))
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue(account.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        request.setValue(method == "PUT" ? "image/png" : "application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pngReply ? "image/png" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        guard limit >= 0, limit <= 4 * 1024 * 1024 else { throw NotebookMediaError.invalidDescriptor }
        let bytes: Data
        let response: HTTPURLResponse
        do { (bytes, response) = try await http.response(for: request, maximumBytes: limit, errorMaximumBytes: 8192, acceptedStatusCodes: 200..<201) }
        catch BoundedHTTPError.responseTooLarge { throw NotebookNetworkError.replyTooLarge }
        catch BoundedHTTPError.invalidResponse { throw NotebookNetworkError.invalidReply }
        guard response.statusCode == 200 else {
            let raw = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["code"] as? String
            let code = raw.flatMap { value in value.utf8.count <= 96 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || $0 == 95 } ? value : nil }
            throw NotebookNetworkError.http(status: response.statusCode, code: code)
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased()
        guard contentType == (pngReply ? "image/png" : "application/json") else { throw NotebookNetworkError.invalidReply }
        return bytes
    }
}
