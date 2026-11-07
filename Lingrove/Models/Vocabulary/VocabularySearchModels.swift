import LingroveNotebook
import Foundation

/// One collected sense is one search destination. The index contains concise meaning material;
/// examples remain evidence for the detail view and never contribute their incidental topics.
nonisolated struct VocabularySearchDocument: Equatable, Sendable, Identifiable {
    let selection: VocabularySelection
    let expression: String
    let dictionaryForm: String
    let meaning: String
    let language: LearningLanguage?
    let fields: [String]
    let text: String
    let fingerprint: String
    var id: UUID { selection.senseID }
}

/// Ranked hits preserve archive identities instead of asking a model to reconstruct expressions.
/// Both keyword-only fallback and hybrid search return this same window navigation value.
nonisolated struct VocabularySearchHit: Equatable, Sendable, Identifiable {
    let document: VocabularySearchDocument
    /// Reciprocal rank fusion is only an ordering weight, not a relevance probability.
    let score: Double
    var id: UUID { document.id }
}

/// A node is a search destination in its own right. Its vector describes the shared meaning,
/// and its sense IDs let the search policy expand only the links in the current filter scope.
nonisolated struct VocabularyMeaningSearchDocument: Sendable, Identifiable {
    let node: VocabularyMeaningNode
    let senseIDs: [UUID]
    let lookupTerms: [String]
    let text: String
    let fingerprint: String
    var id: UUID { node.id }
}

/// One query's presentation data. Sense identity survives ranking and can occur in more than
/// one meaning group when the user has explicitly linked it to several nodes.
nonisolated struct VocabularySearchResults: Sendable {
    struct MeaningGroup: Identifiable, Sendable {
        let node: VocabularyMeaningNode
        let documents: [VocabularySearchDocument]
        var id: UUID { node.id }
    }

    var exact: [VocabularySearchDocument] = []
    var groups: [MeaningGroup] = []
    var other: [VocabularySearchDocument] = []

    var isEmpty: Bool { exact.isEmpty && groups.isEmpty && other.isEmpty }
    var count: Int {
        Set(exact.map(\.id) + groups.flatMap { $0.documents.map(\.id) } + other.map(\.id)).count
    }
}

/// UI state describes usable search, not merely the existence of a downloaded file.
nonisolated enum VocabularySearchStatus: Equatable {
    case notInstalled
    case indexing(completed: Int, total: Int)
    case ready
    case failed(String)
}
