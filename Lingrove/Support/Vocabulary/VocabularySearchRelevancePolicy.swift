import Foundation

/// Query-local admission for the pinned Qwen embedding model, before rank fusion. This pure
/// boundary owns no runtime or settings; both the actor and regression tests use the same rule.
/// These cosine values were calibrated against labeled multilingual expressions, including absent
/// answers and near opposites. They are model-specific distances, never confidence percentages.
/// See docs/benchmarks/vocabulary-search-relevance.md for the corpus, tradeoff and known misses.
nonisolated enum VocabularySearchRelevancePolicy {
    static let minimumSimilarity: Float = 0.48
    static let maximumSimilarityGap: Float = 0.04

    static func isValid(_ value: Float) -> Bool {
        // Normalized Float dot products can round just past 1; reject corrupt/nonfinite scores
        // before they can poison the best score and suppress legitimate neighbors.
        value.isFinite && (-1.001...1.001).contains(value)
    }

    static func cutoff(for similarities: [Float]) -> Float {
        let best = similarities.filter(isValid).max() ?? minimumSimilarity
        // An absolute floor allows an empty result even if a bad candidate ranks first. The
        // additional gap trims the unrelated tail when a much closer candidate is available.
        return max(minimumSimilarity, best - maximumSimilarityGap)
    }
}
