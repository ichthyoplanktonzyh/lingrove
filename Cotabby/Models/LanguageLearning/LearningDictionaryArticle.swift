import Foundation

/// A rendered article contains no native pointers. Resources are resolved for its dictionary
/// identity only; favorites persist the separately attributed plain text rather than executable HTML.
nonisolated struct LearningDictionaryArticle: Equatable, Sendable {
    let html: String
    let text: String
    let sourceName: String
    var sourceURL = ""
    var licenseURL = ""
    var resourceLibrary: UUID?
}

nonisolated struct DictionaryResource: Sendable {
    let data: Data
    let mimeType: String
}

/// WebKit invokes this closure on MainActor; parsing remains on the captured provider actor.
typealias DictionaryResourceLoader = @MainActor (String) async -> DictionaryResource?

extension LearningDictionaryResult {
    nonisolated var estimatedBytes: Int {
        switch self {
        case .notFound: 0
        case .systemText(let text): text.utf8.count
        case .website(let url): url.absoluteString.utf8.count
        case .article(let article): article.html.utf8.count + article.text.utf8.count
        case .entries(let entries): entries.reduce(0) { total, entry in
            total + entry.senses.flatMap(\.definitions).reduce(0) { $0 + $1.utf8.count } + entry.headword.utf8.count
        }
        }
    }
}
