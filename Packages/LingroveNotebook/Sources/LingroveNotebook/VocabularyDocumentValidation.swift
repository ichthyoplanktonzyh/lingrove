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
        guard document.schemaVersion == VocabularyDocument.currentVersion,
              document.schemaVersion >= VocabularyDocument.requiredVersion(for: document.entries),
              Set(document.entries.map(VocabularyIdentityPolicy.entryKey)).count == document.entries.count else {
            throw VocabularyError.invalidArchive
        }
        try VocabularyLifecyclePolicy.validate(document)
        try VocabularyReviewValidation.validateTemplates(document.reviewTemplates ?? [])
        var ids = Set<UUID>()
        for entry in document.entries {
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
        }
        try VocabularySemanticPolicy.validate(document.semantics, entries: document.entries)
        try VocabularyClassificationPolicy.validate(document.classification, nodes: document.semantics.nodes)
    }

    public static func imageReferences(_ document: VocabularyDocument) -> [VocabularyImageReference] {
        let senseImages = document.entries.flatMap { $0.senses.flatMap { sense in
            VocabularyContentPolicy.images(sense.content ?? []) + sense.reviewLayouts.flatMap {
                VocabularyContentPolicy.images($0.customContent)
            }
        } }
        return senseImages + (document.reviewTemplates ?? []).flatMap { VocabularyContentPolicy.images($0.layout.customContent) }
    }

    /// Image staging precedes whole-document preparation. Checking only media here preserves
    /// legitimate edits that still carry stale explanation snapshots until prepare prunes them.
    public static func validateMediaContent(_ next: VocabularyDocument) throws {
        for entry in next.entries {
            for sense in entry.senses {
                try VocabularyContentPolicy.validate(sense.content ?? [])
                for layout in sense.reviewLayouts { try VocabularyReviewValidation.validate(layout) }
            }
        }
        try VocabularyReviewValidation.validateTemplates(next.reviewTemplates ?? [])
    }
}
