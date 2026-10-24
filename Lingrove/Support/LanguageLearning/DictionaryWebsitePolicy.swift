import Foundation

/// A website is an explicit browser action, never a scraped provider or automatic navigation.
/// Percent-encode the query as one opaque component so input cannot change the configured host.
nonisolated enum DictionaryWebsitePolicy {
    static func url(template: String, query: String) -> URL? {
        guard template.utf8.count <= 2048, template.components(separatedBy: "{query}").count == 2,
              DictionaryContentPolicy.validQuery(query) else { return nil }
        // A placeholder in the authority would let dictionary text choose a different host.
        guard let scheme = template.range(of: "://") else { return nil }
        let authority = template[scheme.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.contains("{query}") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, !host.contains("{") else { return nil }
        return url
    }
}
