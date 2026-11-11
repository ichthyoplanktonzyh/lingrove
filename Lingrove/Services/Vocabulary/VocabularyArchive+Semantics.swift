import LingroveNotebook
import Foundation

extension VocabularyArchive {
    /// A sheet produces record-level expectations before borrowing storage. The writer
    /// merges them with its latest checked graph and commits the combined decision atomically.
    func updateMeaningOrganization(_ semantics: VocabularySemanticIndex, basedOn semanticBaseline: VocabularySemanticIndex,
                                   classification: VocabularyClassificationIndex,
                                   basedOn classificationBaseline: VocabularyClassificationIndex) throws -> VocabularyArchiveSnapshot {
        try commitOrganization(.init(semantics: semantics, semanticBaseline: semanticBaseline,
            classification: classification, classificationBaseline: classificationBaseline))
    }

    /// An independently edited meaning keeps concurrent changes to other records. Removing a
    /// meaning also retires its category memberships under the same writer transaction.
    func updateSemantics(_ edited: VocabularySemanticIndex, basedOn baseline: VocabularySemanticIndex) throws -> VocabularyArchiveSnapshot {
        try commitOrganization(.init(semantics: edited, basedOn: baseline))
    }

    func updateClassification(_ edited: VocabularyClassificationIndex,
                              basedOn baseline: VocabularyClassificationIndex) throws -> VocabularyArchiveSnapshot {
        try commitOrganization(.init(classification: edited, basedOn: baseline))
    }

}
