import Foundation

/// Explicit manual creation always makes a new sense under the matching headword. Wording,
/// tags and notes are content, never a semantic identity key. Existing senses are edited or
/// merged by ID through their own commands; this planner performs no classification.
public nonisolated enum VocabularyEntryInputPolicy {
    public struct Plan: Sendable {
        public var document: VocabularyDocument
        public var result = VocabularyEntryImportResult()
    }

    public static func validated(_ input: VocabularyEntryInput) throws -> VocabularyEntryInput {
        var value = input
        value.expression = VocabularyIdentityPolicy.normalized(input.expression)
        value.dictionaryForm = VocabularyIdentityPolicy.normalized(input.dictionaryForm)
        if value.dictionaryForm.isEmpty { value.dictionaryForm = value.expression }
        value.meaning = input.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        value.note = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
        value.example = input.example.trimmingCharacters(in: .whitespacesAndNewlines)
        value.exampleTranslation = input.exampleTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        value.tags = Array(Set(input.tags.map(VocabularyIdentityPolicy.normalized).filter { !$0.isEmpty })).sorted()
        guard !value.expression.isEmpty, value.expression.utf8.count <= 32_000,
              value.dictionaryForm.utf8.count <= 32_000, value.meaning.utf8.count <= 32_000,
              value.note.utf8.count <= 262_144, value.example.utf8.count <= 262_144,
              value.exampleTranslation.utf8.count <= 262_144, value.tags.count <= 64,
              value.tags.allSatisfy({ $0.utf8.count <= 200 && !$0.contains("\0") }),
              ![value.expression, value.dictionaryForm, value.meaning, value.note, value.example, value.exampleTranslation]
                .contains(where: { $0.contains("\0") }) else {
            throw VocabularyEntryInputError.invalidInput
        }
        guard !value.example.isEmpty || value.exampleTranslation.isEmpty else { throw VocabularyEntryInputError.translationWithoutExample }
        return value
    }

    public static func plan(_ inputs: [VocabularyEntryInput], into document: VocabularyDocument, now: Date) throws -> Plan {
        guard !inputs.isEmpty, inputs.count <= 100 else { throw VocabularyEntryInputError.invalidInput }
        var plan = Plan(document: document)
        var entries = document.entries
        for input in inputs {
            try Task.checkCancellation()
            let value = try validated(input)
            let key = VocabularyIdentityPolicy.entryKey(expression: value.expression, language: value.language, kind: value.kind)
            let index: Int
            if let found = entries.firstIndex(where: { VocabularyIdentityPolicy.entryKey($0) == key }) { index = found }
            else {
                index = entries.count
                entries.append(.init(id: UUID(), expression: value.expression, dictionaryForm: value.dictionaryForm,
                    language: value.language, kind: value.kind, senses: [], createdAt: now, updatedAt: now))
                plan.result.addedEntries += 1
            }
            let examples: [VocabularyExample] = value.example.isEmpty ? [] : [
                .init(id: UUID(), sourceKind: .authored, text: value.example, translation: value.exampleTranslation,
                    ranges: VocabularyNotebookQuery.reconciledRanges(in: value.example, expression: value.expression,
                        dictionaryForm: value.dictionaryForm), completeness: .sentence, meaning: "", createdAt: now)
            ]
            let sense = VocabularySense(id: UUID(), meaning: value.meaning, meaningLanguage: value.meaningLanguage,
                meaningOrigin: .user, note: value.note, tags: value.tags, examples: examples,
                createdAt: now, updatedAt: now, createdWithoutContext: examples.isEmpty)
            entries[index].senses.append(sense)
            entries[index].updatedAt = now
            if plan.result.selection == nil { plan.result.selection = .init(entryID: entries[index].id, senseID: sense.id) }
            plan.result.addedSenses += 1
            plan.result.addedExamples += examples.count
            plan.result.addedTranslations += value.exampleTranslation.isEmpty ? 0 : 1
        }
        plan.document.entries = entries
        return plan
    }
}
