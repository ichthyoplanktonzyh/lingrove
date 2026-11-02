import Foundation

/// A transport failure contains no response body or private linguistic data. Hosts may classify
/// cancellation and URL errors separately; byte and redirect failures are always closed locally.
public nonisolated enum BoundedHTTPError: Error, Equatable, Sendable {
    case invalidResponse, responseTooLarge
}

/// Immutable, Foundation-only HTTP resource owner shared by account and notebook adapters.
/// Explicit requests authorize one URL only. A per-task delegate refuses redirects even when an
/// injected URLSession has a different delegate; streamed, decompressed bytes obey the same cap.
public nonisolated struct BoundedHTTPClient: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    @concurrent
    public func response(for original: URLRequest, maximumBytes: Int, errorMaximumBytes: Int? = nil,
                         acceptedStatusCodes: Range<Int> = 200..<300)
        async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard maximumBytes >= 0, errorMaximumBytes.map({ $0 >= 0 }) ?? true else { throw BoundedHTTPError.invalidResponse }
        var request = original
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request, delegate: CloudRedirectFence())
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw BoundedHTTPError.invalidResponse }
        // Some versioned protocols accept exactly 200. A different 2xx is still an error there
        // and must receive the small error-body budget, rather than a multi-MiB success budget.
        let allowed = acceptedStatusCodes.contains(http.statusCode) ? maximumBytes : (errorMaximumBytes ?? maximumBytes)
        guard http.expectedContentLength <= Int64(allowed) else { throw BoundedHTTPError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(allowed, 16_384))
        for try await byte in stream {
            guard data.count < allowed else { throw BoundedHTTPError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, http)
    }
}

/// Immutable delegate lifetime follows each task; no redirect can replay a bearer or POST body.
private nonisolated final class CloudRedirectFence: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
