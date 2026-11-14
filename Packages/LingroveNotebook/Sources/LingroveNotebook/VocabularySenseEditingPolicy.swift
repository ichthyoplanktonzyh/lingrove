import Foundation

/// Detached editors and archive transactions share sense edits. Stable aliases retain
/// historical review ownership; source evidence and tool memory remain independently owned.
public nonisolated enum VocabularySenseEditingPolicy {
    /// Tags are sense annotations, not a separate catalog. The archive applies this to every
    /// entry in one transaction; an open editor uses it without dates to rebase only the deleted
    /// tag in its baseline/draft, preserving all other unsaved fields and conflict detection.
    @discardableResult
    public static func removeTag(_ tag: String, from entry: inout VocabularyEntry, now: Date? = nil) -> Bool {
        var changed = false
        for index in entry.senses.indices where entry.senses[index].tags.contains(tag) {
            entry.senses[index].tags.removeAll { $0 == tag }
            if let now { entry.senses[index].updatedAt = now }
            changed = true
        }
        if changed, let now { entry.updatedAt = now }
        return changed
    }

    /// Both GUI and CLI submit one complete graph change. Reconcile before dry-run validation
    /// as well as persistence, so source associations cannot become dangling references.
    public static func remove(entryID: UUID, senseID: UUID, from document: inout VocabularyDocument) throws {
        let previousEntries = document.entries
        _ = try remove(entryID: entryID, senseID: senseID, from: &document, previousEntries: previousEntries)
    }

    /// The connection may already have the joined entries. Work on the canonical header and
    /// claims directly so deleting one sense never recreates the surviving source evidence.
    static func remove(entryID: UUID, senseID: UUID, from document: inout VocabularyDocument,
                       previousEntries: [VocabularyEntry], reconcilingSemantics: Bool = true) throws -> [VocabularyEntry] {
        var entries = previousEntries
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              let sense = entries[index].senses.firstIndex(where: { $0.id == senseID }) else {
            throw NotebookToolError(code: .notFound, message: "Sense does not belong to this entry.")
        }
        let original = entries[index]
        entries[index].senses.remove(at: sense)
        document.catalog[index].senses.remove(at: sense)
        if entries[index].senses.isEmpty {
            entries.remove(at: index)
            document.catalog.remove(at: index)
        }
        document.interpretations.removeAll { $0.senseID == senseID && $0.status == .accepted }
        for index in document.interpretations.indices where document.interpretations[index].senseID == senseID {
            document.interpretations[index].senseID = nil
            document.interpretations[index].status = .candidate
        }
        if reconcilingSemantics {
            VocabularySemanticPolicy.reconcileEntry(&document.semantics, previous: original, current: entries.first { $0.id == entryID })
        }
        return entries
    }

    public static func merge(entryID: UUID, source: UUID, into target: UUID,
                             in document: inout VocabularyDocument, now: Date) throws {
        let before = document
        var entries = document.entries
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        try merge(source: source, into: target, in: &entries[index], now: now)
        document.entries = entries
        VocabularySemanticPolicy.reconcile(&document.semantics, previous: before, entries: entries)
    }

    public static func merge(source: UUID, into target: UUID, in entry: inout VocabularyEntry, now: Date) throws {
        guard let from = entry.senses.firstIndex(where: { $0.id == source }),
              let to = entry.senses.firstIndex(where: { $0.id == target }), from != to else {
            throw VocabularyError.invalidContent
        }
        let original = entry.senses[from]
        var merged = entry.senses[to]
        // The drop destination owns all authored content, even an intentionally empty field.
        // Only evidence moves. Equal sentence text from different sources remains distinct.
        for example in original.examples {
            if let index = merged.examples.firstIndex(where: {
                $0.id == example.id || ($0.sourceID == example.sourceID &&
                    $0.ranges == example.ranges && $0.text == example.text &&
                    $0.completeness == example.completeness)
            }) {
                let translations = [VocabularyMeaning(text: example.translation, language: example.translationLanguage)]
                    + example.translationVariants
                for value in translations where !value.text.isEmpty &&
                    !merged.examples[index].translationVariants.contains(value) {
                    merged.examples[index].translationVariants.append(value)
                }
            } else { merged.examples.append(example) }
        }
        // Collection and review receipts are lifecycle identities, not shared explanation text.
        // Keeping aliases prevents in-flight receipts and historical review ownership from dangling.
        merged.isSavedWithoutContext = merged.isSavedWithoutContext || original.isSavedWithoutContext
        merged.mergedFrom = Array(Set(merged.mergedFrom + [original.id] + original.mergedFrom))
            .sorted { $0.uuidString < $1.uuidString }
        merged.updatedAt = now
        entry.senses[to] = merged
        entry.senses.remove(at: from)
        entry.updatedAt = now
    }

}
