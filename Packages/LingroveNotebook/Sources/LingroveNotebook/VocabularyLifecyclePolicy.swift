import Foundation
import LingroveTextRules

/// Referential integrity is checked before every archive transaction, including dry runs.
/// Source evidence may outlive an interpretation. Only accepted interpretations with a saved
/// sense appear as examples, while tentative readings remain available for later editing.
public nonisolated enum VocabularyLifecyclePolicy {
    public static func validate(_ document: VocabularyDocument) throws {
        let senses = document.catalog.flatMap(\.senses)
        let senseIDs = Set(senses.map(\.id))
        guard Set(document.sources.map(\.id)).count == document.sources.count,
              Set(document.occurrences.map(\.id)).count == document.occurrences.count,
              Set(document.interpretations.map(\.id)).count == document.interpretations.count else {
            throw VocabularyError.invalidArchive
        }
        for sense in senses {
            guard sense.examples.isEmpty, sense.note.utf8.count <= 262_144, sense.tags.count <= 100,
                  sense.tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }),
                  sense.savedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
                throw VocabularyError.invalidArchive
            }
        }
        let sources = Dictionary(uniqueKeysWithValues: document.sources.map { ($0.id, $0) })
        let occurrences = Dictionary(uniqueKeysWithValues: document.occurrences.map { ($0.id, $0) })
        // The context-free capture control needs one stable destination per headword.
        guard document.catalog.allSatisfy({ $0.senses.filter(\.isSavedWithoutContext).count <= 1 }) else {
            throw VocabularyError.invalidArchive
        }
        try validateEvidence(document, sources: sources)
        try validateClaims(document.interpretations, senseIDs: senseIDs, occurrences: occurrences)
    }

    private static func validateEvidence(_ document: VocabularyDocument, sources: [UUID: VocabularySourceSnapshot]) throws {
        for source in document.sources {
            guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.text.utf8.count <= 262_144,
                  (source.appBundleIdentifier?.utf8.count ?? 0) <= 1_024, source.encounteredAt.timeIntervalSince1970.isFinite else {
                throw VocabularyError.invalidArchive
            }
        }
        for occurrence in document.occurrences {
            guard let source = sources[occurrence.sourceID], occurrence.ranges.count <= 64,
                  occurrence.ranges.allSatisfy({ UTF16TextRangePolicy.isValid($0.nsRange, in: source.text) }) else {
                throw VocabularyError.invalidArchive
            }
        }
    }

    private static func validateClaims(_ claims: [VocabularyInterpretation], senseIDs: Set<UUID>,
                                       occurrences: [UUID: VocabularySourceOccurrence]) throws {
        var accepted = Set<UUID>()
        for claim in claims {
            guard occurrences[claim.occurrenceID] != nil, claim.senseID.map({ senseIDs.contains($0) }) ?? true,
                  claim.status != .accepted || (claim.senseID != nil && accepted.insert(claim.occurrenceID).inserted),
                  claim.meaning.utf8.count <= 32_000, claim.translation.utf8.count <= 262_144,
                  claim.translationVariants.count <= 64, claim.explanations.count <= 24,
                  claim.provenance.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  claim.createdAt.timeIntervalSince1970.isFinite else { throw VocabularyError.invalidArchive }
            for record in claim.explanations {
                guard VocabularyExplanationValidation.isValid(record.input), VocabularyExplanationValidation.isValid(record.result) else {
                    throw VocabularyError.invalidArchive
                }
            }
        }
    }
}
