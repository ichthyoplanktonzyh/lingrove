import Foundation

/// Referential integrity is checked before every archive transaction, including dry runs.
/// Evidence can exist without claims and claims without collection membership; these are valid
/// states rather than orphans to collect automatically. Deletion must explicitly remove links.
nonisolated enum VocabularyLifecyclePolicy {
    static func validate(_ document: VocabularyDocument) throws {
        let senses = document.catalog.flatMap(\.senses)
        let senseIDs = Set(senses.map(\.id))
        guard Set(document.sources.map(\.id)).count == document.sources.count,
              Set(document.occurrences.map(\.id)).count == document.occurrences.count,
              Set(document.interpretations.map(\.id)).count == document.interpretations.count,
              Set(document.collections.map(\.senseID)).count == document.collections.count else {
            throw VocabularyError.invalidArchive
        }
        for sense in senses {
            guard sense.examples.isEmpty, sense.note.isEmpty, sense.tags.isEmpty, !sense.isSavedWithoutContext,
                  sense.content == nil, sense.review == nil, sense.reviewCards == nil else { throw VocabularyError.invalidArchive }
        }
        let sources = Dictionary(uniqueKeysWithValues: document.sources.map { ($0.id, $0) })
        let occurrences = Dictionary(uniqueKeysWithValues: document.occurrences.map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: document.interpretations.map { ($0.id, $0) })
        let standalone = Set(document.collections.filter(\.isSavedWithoutContext).map(\.senseID))
        // A floating word-only favorite has no sense destination. Preserve its unique slot;
        // other collected senses remain independent manual meanings with this flag unset.
        guard document.catalog.allSatisfy({ entry in
            entry.senses.filter { standalone.contains($0.id) }.count <= 1
        }) else { throw VocabularyError.invalidArchive }
        try validateEvidence(document, sources: sources)
        try validateClaims(document.interpretations, senseIDs: senseIDs, occurrences: occurrences)
        try validateCollections(document.collections, senseIDs: senseIDs, claims: claims)
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
                  occurrence.ranges.allSatisfy({ VocabularyPolicy.valid($0.nsRange, in: source.text) }) else {
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
                guard LearningExplanationPolicy.isValid(record.input), LearningExplanationPolicy.isValid(record.result) else {
                    throw VocabularyError.invalidArchive
                }
            }
        }
    }

    private static func validateCollections(_ collections: [VocabularyCollectionItem], senseIDs: Set<UUID>,
                                            claims: [UUID: VocabularyInterpretation]) throws {
        for collection in collections {
            guard senseIDs.contains(collection.senseID), collection.interpretationIDs.count <= 10_000,
                  Set(collection.interpretationIDs).count == collection.interpretationIDs.count,
                  collection.interpretationIDs.allSatisfy({
                      claims[$0]?.senseID == collection.senseID && claims[$0]?.status == .accepted
                  }), collection.note.utf8.count <= 262_144, collection.tags.count <= 100,
                  collection.tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }) else { throw VocabularyError.invalidArchive }
        }
    }
}
