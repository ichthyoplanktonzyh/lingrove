import Foundation
import LingroveTextRules

/// One pure document boundary is shared by the Mac archive and Nibomo's notebook store. It
/// checks saved values without opening a database, selecting a review tool or generating text.
/// Stores retain transaction/revision ownership and commit only the candidate returned by prepare.
public nonisolated enum VocabularyDocumentValidation {
    public static let maximumBackupBytes = 192 * 1_024 * 1_024
    public static let maximumMediaBytes = 128 * 1_024 * 1_024

    /// Editing may carry old explanation snapshots. Reconcile against the transaction baseline,
    /// then prune stale snapshots before final validation. Strict backup validation uses validate
    /// directly instead; it must reject invalid input rather than silently repair an import.
    public static func prepare(
        _ document: VocabularyDocument, previous: VocabularyDocument, restoringBackup: Bool = false
    ) throws -> VocabularyDocument {
        guard document.schemaVersion == VocabularyDocument.currentVersion else { throw VocabularyError.unsupportedVersion }
        var next = document
        try VocabularyLifecyclePolicy.validate(next)
        if !restoringBackup {
            VocabularySemanticPolicy.reconcile(&next.semantics, previous: previous, entries: next.entries)
        }
        var entries = next.entries
        for index in entries.indices {
            let entry = entries[index]
            for sense in entry.senses.indices {
                let value = entry.senses[sense]
                let input = VocabularyExplanationIdentity.input(for: entry, sense: value, example: nil)
                entries[index].senses[sense].explanations = value.explanations.filter { $0.input == input }
                for usage in value.examples.indices {
                    let input = VocabularyExplanationIdentity.input(for: entry, sense: value, example: value.examples[usage])
                    entries[index].senses[sense].examples[usage].explanations = value.examples[usage].explanations.filter { $0.input == input }
                }
            }
        }
        next.entries = entries
        next.schemaVersion = VocabularyDocument.requiredVersion(for: entries)
        try validate(next)
        return next
    }

    /// Keep the historical identity scopes and insertion order. Expanding this namespace to
    /// explanation, binding or template IDs would reject previously valid notebooks.
    public static func validate(_ document: VocabularyDocument) throws {
        _ = try validate(document, entries: document.entries)
    }

    static func validate(_ document: VocabularyDocument, entries: [VocabularyEntry]) throws -> [UUID: Set<UUID>] {
        guard document.schemaVersion == VocabularyDocument.currentVersion,
              document.schemaVersion >= VocabularyDocument.requiredVersion(for: entries),
              Set(entries.map(VocabularyIdentityPolicy.entryKey)).count == entries.count else {
            throw VocabularyError.invalidArchive
        }
        try VocabularyLifecyclePolicy.validate(document)
        try VocabularyReviewValidation.validateTemplates(document.reviewTemplates ?? [])
        var allIDs = Set<UUID>(), identifiers: [UUID: Set<UUID>] = [:]
        for entry in entries {
            let ids = try entryIdentifiers(entry)
            guard allIDs.isDisjoint(with: ids) else { throw VocabularyError.invalidArchive }
            allIDs.formUnion(ids); identifiers[entry.id] = ids
        }
        try VocabularySemanticPolicy.validate(document.semantics, entries: entries)
        try VocabularyClassificationPolicy.validate(document.classification, nodes: document.semantics.nodes)
        return identifiers
    }

    /// IDs retain the historical cross-entry namespace; explanation and binding IDs stay local.
    static func entryIdentifiers(_ entry: VocabularyEntry) throws -> Set<UUID> {
        var ids = Set<UUID>()
        guard ids.insert(entry.id).inserted, !VocabularyIdentityPolicy.normalized(entry.expression).isEmpty else {
            throw VocabularyError.invalidArchive
        }
        for sense in entry.senses {
            try VocabularyContentPolicy.validate(sense.content ?? [])
            for block in sense.content ?? [] {
                guard ids.insert(block.id).inserted else { throw VocabularyError.invalidArchive }
            }
            if let review = sense.review { try VocabularyReviewValidation.validate(review) }
            try VocabularyReviewValidation.validateCards(sense.reviewCards ?? [], ids: &ids)
            let input = VocabularyExplanationIdentity.input(for: entry, sense: sense, example: nil)
            guard ids.insert(sense.id).inserted, sense.mergedFrom.allSatisfy({ ids.insert($0).inserted }),
                  sense.explanations.count <= 128,
                  sense.explanations.allSatisfy({
                      VocabularyExplanationValidation.isValid($0.input) && VocabularyExplanationValidation.isValid($0.result) &&
                          $0.input == input
                  }) else { throw VocabularyError.invalidArchive }
            for usage in sense.examples {
                let input = VocabularyExplanationIdentity.input(for: entry, sense: sense, example: usage)
                guard ids.insert(usage.id).inserted, !usage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      usage.text.utf8.count <= 262_144,
                      usage.ranges.allSatisfy({ UTF16TextRangePolicy.isValid($0.nsRange, in: usage.text) }),
                      usage.explanations.count <= 24, usage.explanations.allSatisfy({
                          VocabularyExplanationValidation.isValid($0.input) && VocabularyExplanationValidation.isValid($0.result) &&
                              $0.input == input
                      }) else { throw VocabularyError.invalidArchive }
            }
        }
        return ids
    }

    static func pruningExplanations(_ entry: VocabularyEntry) -> VocabularyEntry {
        var next = entry
        for index in entry.senses.indices {
            let sense = entry.senses[index]
            let input = VocabularyExplanationIdentity.input(for: entry, sense: sense, example: nil)
            next.senses[index].explanations = sense.explanations.filter { $0.input == input }
            for usage in sense.examples.indices {
                let input = VocabularyExplanationIdentity.input(for: entry, sense: sense, example: sense.examples[usage])
                next.senses[index].examples[usage].explanations = sense.examples[usage].explanations.filter { $0.input == input }
            }
        }
        return next
    }

    public static func imageReferences(_ document: VocabularyDocument) -> [VocabularyImageReference] {
        let personal = document.catalog.flatMap(\.senses).flatMap { sense in
            VocabularyContentPolicy.images(sense.content ?? []) + senseLayouts(sense).flatMap {
                VocabularyContentPolicy.images($0.customContent)
            }
        }
        return personal + (document.reviewTemplates ?? []).flatMap { VocabularyContentPolicy.images($0.layout.customContent) }
    }

    private static func senseLayouts(_ sense: VocabularySense) -> [ReviewLayout] {
        ([sense.review].compactMap { $0 } + (sense.reviewCards ?? [])).flatMap {
            ([$0.plan] + $0.preservedPlans).compactMap(\.layout)
        }
    }

    /// Image staging precedes whole-document preparation. Checking only media here preserves
    /// legitimate edits that still carry stale explanation snapshots until prepare prunes them.
    public static func validateMediaContent(_ next: VocabularyDocument) throws {
        for sense in next.catalog.flatMap(\.senses) {
            try VocabularyContentPolicy.validate(sense.content ?? [])
            for layout in senseLayouts(sense) { try VocabularyReviewValidation.validate(layout) }
        }
        try VocabularyReviewValidation.validateTemplates(next.reviewTemplates ?? [])
    }
}
