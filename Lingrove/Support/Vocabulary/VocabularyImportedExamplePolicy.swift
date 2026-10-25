import Foundation

/// Imported sentences reuse the notebook's usage identity without moving an existing usage to
/// another meaning. The batch planner owns lookup indexes; this pure boundary owns append/merge
/// rules and reports actual changes so example-only imports can be previewed and committed.
nonisolated enum VocabularyImportedExamplePolicy {
    struct Location { let sense: Int; let example: Int }
    /// The planner resolves ownership once from its index; append never guesses a destination.
    struct Lookup { let matching: [Int]; let existing: Location? }
    struct Change {
        let senseID: UUID
        var addedSense = false
        var addedExample = false
        var addedTranslation = false
        let location: Location
        var changed: Bool { addedSense || addedExample || addedTranslation }
    }

    static func example(_ input: VocabularyEntryInput, now: Date) -> VocabularyExample? {
        guard !input.example.isEmpty else { return nil }
        // The user supplied the complete sentence cell. Preserve all its text; the AX capture
        // helper would crop it. Missing literal matches retain the sentence with empty highlights.
        return .init(id: UUID(), text: input.example, translation: input.exampleTranslation,
            ranges: VocabularyPolicy.reconciledRanges(in: input.example, expression: input.expression,
                dictionaryForm: input.dictionaryForm),
            completeness: .sentence, meaning: "", createdAt: now)
    }

    static func append(
        _ input: VocabularyEntryInput, example: VocabularyExample, to entry: inout VocabularyEntry,
        lookup: Lookup, now: Date
    ) throws -> Change {
        if let existing = lookup.existing {
            let hasAnnotations = !input.meaning.isEmpty || !input.note.isEmpty || !input.tags.isEmpty
            guard !hasAnnotations || lookup.matching.contains(existing.sense) else { throw VocabularyWordListError.exampleConflict }
            var usage = entry.senses[existing.sense].examples[existing.example]
            let changed = addTranslation(example.translation, to: &usage)
            if changed {
                entry.senses[existing.sense].examples[existing.example] = usage
                entry.senses[existing.sense].updatedAt = now; entry.updatedAt = now
            }
            return .init(senseID: entry.senses[existing.sense].id, addedTranslation: changed, location: existing)
        }
        // A supplied, unambiguous core meaning can group usages. With no meaning, a fresh
        // context owns its own sense rather than inferring that equal headwords mean the same.
        let target = !input.meaning.isEmpty && lookup.matching.count == 1 ? lookup.matching.first : nil
        let index = target ?? entry.senses.count
        if target == nil {
            entry.senses.append(.init(id: UUID(), meaning: input.meaning, meaningLanguage: input.meaningLanguage,
                meaningOrigin: input.meaning.isEmpty ? .captured : .user, note: input.note, tags: input.tags,
                createdAt: now, updatedAt: now))
        }
        let usageIndex = entry.senses[index].examples.count
        entry.senses[index].examples.append(example)
        entry.senses[index].updatedAt = now; entry.updatedAt = now
        return .init(senseID: entry.senses[index].id, addedSense: target == nil, addedExample: true,
            addedTranslation: !example.translation.isEmpty, location: .init(sense: index, example: usageIndex))
    }

    private static func addTranslation(_ text: String, to example: inout VocabularyExample) -> Bool {
        guard !text.isEmpty else { return false }
        if example.translation == text || example.translationVariants.contains(where: { $0.text == text }) { return false }
        if example.translation.isEmpty { example.translation = text; example.translationLanguage = nil
        } else { example.translationVariants.append(.init(text: text, language: nil)) }
        // These two CSV columns provide no translation-language metadata. Preserve unknown
        // provenance rather than borrowing the independent core-meaning language setting.
        return true
    }
}
