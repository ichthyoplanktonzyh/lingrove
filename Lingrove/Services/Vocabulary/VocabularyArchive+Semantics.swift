import Foundation

extension VocabularyArchive {
    /// One synchronous actor transaction merges a detached sheet draft against the live index.
    /// Lexical captures arriving while the sheet is open are retained. No model or endpoint is
    /// invoked: a suggested relation can only enter this index with its provenance attached.
    func updateSemantics(_ edited: VocabularySemanticIndex, basedOn baseline: VocabularySemanticIndex) throws -> VocabularySnapshot {
        var next = try load().document
        next.semantics = try VocabularySemanticPolicy.merge(edited, baseline: baseline, current: next.semantics)
        try VocabularySemanticPolicy.validate(next.semantics, entries: next.entries)
        return try commit(next)
    }
}
