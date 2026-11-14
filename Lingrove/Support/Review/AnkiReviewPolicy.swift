import Foundation
import LingroveNotebook

/// Both connection setup and HTTP transport use the same bounded loopback address policy.
/// Note types own exported fields/templates; the transport owns only endpoint admission.
nonisolated enum AnkiReviewPolicy {
    static func endpoint(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http", let host = parts.host,
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        var normalized = parts; normalized.host = host.lowercased(); normalized.path = ""
        return normalized.url
    }
}
