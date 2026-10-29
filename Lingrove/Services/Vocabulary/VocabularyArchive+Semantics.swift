import Foundation

extension VocabularyArchive {
    /// One synchronous actor transaction merges a detached sheet draft against the live index.
    /// Lexical captures arriving while the sheet is open are retained. No model or endpoint is
    /// invoked: a suggested relation can only enter this index with its provenance attached.
    func updateSemantics(_ edited: VocabularySemanticIndex, basedOn baseline: VocabularySemanticIndex) throws -> VocabularySnapshot {
        var next = try load().document
        next.semantics = try VocabularySemanticPolicy.merge(edited, baseline: baseline, current: next.semantics)
        let removed = Set(baseline.nodes.map(\.id)).subtracting(next.semantics.nodes.map(\.id))
        next.classification.memberships.removeAll { removed.contains($0.nodeID) }
        try VocabularySemanticPolicy.validate(next.semantics, entries: next.entries)
        return try commit(next)
    }

    /// The store passes detached UI drafts to the same actor as CLI transactions. A renamed
    /// category and an independently captured expression can therefore commit without clobbering.
    func updateClassification(_ edited: VocabularyClassificationIndex,
                              basedOn baseline: VocabularyClassificationIndex) throws -> VocabularySnapshot {
        var next = try load().document
        next.classification = try VocabularyClassificationPolicy.merge(edited, baseline: baseline, current: next.classification)
        try VocabularyClassificationPolicy.validate(next.classification, nodes: next.semantics.nodes)
        return try commit(next)
    }
}
