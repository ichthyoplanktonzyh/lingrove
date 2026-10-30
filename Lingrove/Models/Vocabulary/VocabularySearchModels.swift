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

/// UI state describes usable search, not merely the existence of a downloaded file.
nonisolated enum VocabularySearchStatus: Equatable {
    case notInstalled
    case indexing(completed: Int, total: Int)
    case ready
    case failed(String)
}
