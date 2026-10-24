import Foundation

/// Dictionary markup is content, not navigation authority. Only an explicit activated link can
/// leave the card; cross-references remain bounded lookup queries and never open local files.
nonisolated enum DictionaryLinkPolicy {
    static func externalURL(_ value: String) -> URL? {
        guard value.utf8.count <= 4096, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func reference(_ url: URL) -> String? {
        guard ["entry", "bword"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let raw = url.absoluteString.components(separatedBy: "://").dropFirst().joined(separator: "://")
        let query = (raw.removingPercentEncoding ?? raw).components(separatedBy: "#")[0]
        return DictionaryContentPolicy.validQuery(query) ? query : nil
    }
}
