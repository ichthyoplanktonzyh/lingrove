import Foundation

/// Non-destructive addition is shared by manual creation and import. It groups headwords by
/// the notebook's existing identity, appends distinct meanings, and never rewrites saved senses,
/// notes, review bindings or examples. The archive runs this plan inside its write transaction.
nonisolated enum VocabularyEntryInputPolicy {
    struct Plan {
        var document: VocabularyDocument
        var result = VocabularyEntryImportResult()
    }

    private struct SenseKey: Hashable {
        let meaning: String
        let language: LearningLanguage?
        let note: String
        let tags: [String]
    }

    static func validated(_ input: VocabularyEntryInput) throws -> VocabularyEntryInput {
        var value = input
        value.expression = VocabularyPolicy.normalized(input.expression)
        value.dictionaryForm = VocabularyPolicy.normalized(input.dictionaryForm)
        if value.dictionaryForm.isEmpty { value.dictionaryForm = value.expression }
        value.meaning = input.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        value.note = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
        value.tags = Array(Set(input.tags.map(VocabularyPolicy.normalized).filter { !$0.isEmpty })).sorted()
        guard !value.expression.isEmpty, value.expression.utf8.count <= 32_000,
              value.dictionaryForm.utf8.count <= 32_000, value.meaning.utf8.count <= 32_000,
              value.note.utf8.count <= 262_144, value.tags.count <= 64,
              value.tags.allSatisfy({ $0.utf8.count <= 200 && !$0.contains("\0") }),
              ![value.expression, value.dictionaryForm, value.meaning, value.note].contains(where: { $0.contains("\0") }) else {
            throw VocabularyWordListError.invalidInput
        }
        return value
    }

    static func plan(_ inputs: [VocabularyEntryInput], into document: VocabularyDocument, now: Date) throws -> Plan {
        guard !inputs.isEmpty else { throw VocabularyWordListError.empty }
        guard inputs.count <= VocabularyWordListPolicy.maximumRows else { throw VocabularyWordListError.tooLarge }
        var plan = Plan(document: document)
        var indices = Dictionary(uniqueKeysWithValues: document.entries.enumerated().map {
            (VocabularyPolicy.entryKey($0.element), $0.offset)
        })
        var keys: [Int: Set<SenseKey>] = [:]
        for input in inputs {
            try Task.checkCancellation()
            let value = try validated(input)
            let capture = VocabularyCapture(expression: value.expression, dictionaryForm: value.dictionaryForm,
                language: value.language, kind: value.kind)
            let key = VocabularyPolicy.entryKey(capture)
            let index: Int
            if let found = indices[key] { index = found } else {
                index = plan.document.entries.count
                indices[key] = index
                plan.document.entries.append(VocabularyEntry(id: UUID(), expression: value.expression,
                    dictionaryForm: value.dictionaryForm, language: value.language, kind: value.kind,
                    senses: [], createdAt: now, updatedAt: now))
                plan.result.addedEntries += 1
            }
            let entry = plan.document.entries[index]
            if keys[index] == nil { keys[index] = Set(entry.senses.flatMap { keysForSense($0) }) }
            let candidate = SenseKey(meaning: VocabularyPolicy.normalized(value.meaning),
                language: value.meaning.isEmpty ? nil : value.meaningLanguage, note: value.note, tags: value.tags)
            let bareWord = value.meaning.isEmpty && value.note.isEmpty && value.tags.isEmpty
            if !entry.senses.isEmpty, bareWord || keys[index, default: []].contains(candidate) {
                plan.result.skippedRows += 1
                if plan.result.selection == nil, let sense = entry.senses.first {
                    plan.result.selection = .init(entryID: entry.id, senseID: sense.id)
                }
                continue
            }
            // Explicit senses are not the single context-free capture slot used by favorite
            // buttons. This preserves independent imported meanings and the existing graph invariant.
            let sense = VocabularySense(id: UUID(), meaning: value.meaning, meaningLanguage: value.meaningLanguage,
                meaningOrigin: value.meaning.isEmpty ? .captured : .user, note: value.note, tags: value.tags,
                createdAt: now, updatedAt: now, createdWithoutContext: true)
            plan.document.entries[index].senses.append(sense)
            plan.document.entries[index].updatedAt = now
            keys[index, default: []].formUnion(keysForSense(sense))
            let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
            if plan.result.addedSenses == 0 { plan.result.selection = selection }
            plan.result.addedSenses += 1
        }
        return plan
    }

    private static func keysForSense(_ sense: VocabularySense) -> [SenseKey] {
        let meanings = [VocabularyMeaning(text: sense.meaning, language: sense.meaningLanguage)]
            + sense.standaloneMeanings + sense.alternateMeanings
        let note = sense.note.trimmingCharacters(in: .whitespacesAndNewlines), tags = sense.tags.sorted()
        // An unspecified import language cannot prove the same text is a different meaning.
        // Include preserved translations/merged labels without changing their current owner.
        return meanings.flatMap { value in
            let meaning = VocabularyPolicy.normalized(value.text)
            return [SenseKey(meaning: meaning, language: meaning.isEmpty ? nil : value.language, note: note, tags: tags),
                    SenseKey(meaning: meaning, language: nil, note: note, tags: tags)]
        }
    }
}
