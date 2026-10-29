import Foundation

extension VocabularyArchive {
    /// A meaning, expression links and directory edits are one user task. Both draft merges
    /// finish before the single SQL commit, so a conflict leaves neither half saved.
    func updateMeaningOrganization(_ semantics: VocabularySemanticIndex, basedOn semanticBaseline: VocabularySemanticIndex,
                                   classification: VocabularyClassificationIndex,
                                   basedOn classificationBaseline: VocabularyClassificationIndex) throws -> VocabularySnapshot {
        var next = try load().document
        next.semantics = try VocabularySemanticPolicy.merge(semantics, baseline: semanticBaseline, current: next.semantics)
        next.classification = try VocabularyClassificationPolicy.merge(classification, baseline: classificationBaseline,
            current: next.classification)
        try VocabularySemanticPolicy.validate(next.semantics, entries: next.entries)
        try VocabularyClassificationPolicy.validate(next.classification, nodes: next.semantics.nodes)
        return try commit(next)
    }

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
