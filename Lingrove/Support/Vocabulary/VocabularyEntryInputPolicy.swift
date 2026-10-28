import Foundation

/// Non-destructive addition is shared by manual creation and import. It groups headwords by
/// the notebook's existing identity, appends distinct meanings, and never rewrites saved senses,
/// notes, review bindings or examples. The archive runs this plan inside its write transaction.
nonisolated enum VocabularyEntryInputPolicy {
    struct Plan {
        var document: VocabularyDocument
        var result = VocabularyEntryImportResult()
        var selectedInterpretations: [UUID: Set<UUID>] = [:]

        mutating func collect(senseID: UUID, interpretationID: UUID? = nil) {
            if selectedInterpretations[senseID] == nil { selectedInterpretations[senseID] = [] }
            if let interpretationID { selectedInterpretations[senseID]?.insert(interpretationID) }
        }

        /// Importing is an explicit personal save even when an external agent already created
        /// the knowledge. Collect by identity without rebuilding or duplicating that knowledge.
        mutating func applyCollections(now: Date) {
            let offsets = Dictionary(uniqueKeysWithValues: document.collections.enumerated().map { ($0.element.senseID, $0.offset) })
            for (senseID, ids) in selectedInterpretations {
                let index = offsets[senseID]
                var collection = index.map { document.collections[$0] } ?? .init(senseID: senseID, savedAt: now)
                let before = collection
                let retained = Set(collection.interpretationIDs)
                collection.interpretationIDs += ids.subtracting(retained).sorted { $0.uuidString < $1.uuidString }
                if let index {
                    if collection != before { document.collections[index] = collection; result.changedCollections += 1 }
                } else { document.collections.append(collection); result.changedCollections += 1 }
            }
        }

        mutating func record(_ change: VocabularyImportedExamplePolicy.Change, entryID: UUID) {
            if change.changed && !result.hasChanges || result.selection == nil {
                result.selection = .init(entryID: entryID, senseID: change.senseID)
            }
            result.addedSenses += change.addedSense ? 1 : 0
            result.addedExamples += change.addedExample ? 1 : 0
            result.addedTranslations += change.addedTranslation ? 1 : 0
            if !change.changed { result.skippedRows += 1 }
        }
    }

    private struct SenseKey: Hashable {
        let meaning: String
        let language: LearningLanguage?
        let note: String
        let tags: [String]
    }

    /// Per-headword lookup keeps repeated CSV rows linear in the imported example count.
    /// Offsets remain stable because this append-only plan never removes or reorders senses/usages.
    private struct EntryIndex {
        var senses: [SenseKey: [Int]] = [:]
        var examples: [String: VocabularyImportedExamplePolicy.Location] = [:]

        init(_ entry: VocabularyEntry) {
            for (index, sense) in entry.senses.enumerated() { include(sense, at: index) }
        }

        mutating func include(_ sense: VocabularySense, at index: Int) {
            for key in Set(keysForSense(sense)) { senses[key, default: []].append(index) }
            for (usage, example) in sense.examples.enumerated() {
                examples[VocabularyPolicy.exampleKey(example)] = .init(sense: index, example: usage)
            }
        }

        mutating func record(_ change: VocabularyImportedExamplePolicy.Change, key: String, entry: VocabularyEntry) {
            if change.addedSense, let sense = entry.senses.last { include(sense, at: entry.senses.count - 1) }
            examples[key] = change.location
        }
    }

    static func validated(_ input: VocabularyEntryInput) throws -> VocabularyEntryInput {
        var value = input
        value.expression = VocabularyPolicy.normalized(input.expression)
        value.dictionaryForm = VocabularyPolicy.normalized(input.dictionaryForm)
        if value.dictionaryForm.isEmpty { value.dictionaryForm = value.expression }
        value.meaning = input.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        value.note = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
        value.example = input.example.trimmingCharacters(in: .whitespacesAndNewlines)
        value.exampleTranslation = input.exampleTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        value.tags = Array(Set(input.tags.map(VocabularyPolicy.normalized).filter { !$0.isEmpty })).sorted()
        guard !value.expression.isEmpty, value.expression.utf8.count <= 32_000,
              value.dictionaryForm.utf8.count <= 32_000, value.meaning.utf8.count <= 32_000,
              value.note.utf8.count <= 262_144, value.example.utf8.count <= 262_144,
              value.exampleTranslation.utf8.count <= 262_144, value.tags.count <= 64,
              value.tags.allSatisfy({ $0.utf8.count <= 200 && !$0.contains("\0") }),
              ![value.expression, value.dictionaryForm, value.meaning, value.note, value.example, value.exampleTranslation]
                .contains(where: { $0.contains("\0") }) else {
            throw VocabularyWordListError.invalidInput
        }
        guard !value.example.isEmpty || value.exampleTranslation.isEmpty else { throw VocabularyWordListError.translationWithoutExample }
        return value
    }

    static func plan(_ inputs: [VocabularyEntryInput], into document: VocabularyDocument, now: Date) throws -> Plan {
        guard !inputs.isEmpty else { throw VocabularyWordListError.empty }
        guard inputs.count <= VocabularyWordListPolicy.maximumRows else { throw VocabularyWordListError.tooLarge }
        var plan = Plan(document: document)
        var entries = document.entries
        var indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map {
            (VocabularyPolicy.entryKey($0.element), $0.offset)
        })
        var keys: [Int: EntryIndex] = [:]
        for input in inputs {
            try Task.checkCancellation()
            let value = try validated(input)
            let capture = VocabularyCapture(expression: value.expression, dictionaryForm: value.dictionaryForm,
                language: value.language, kind: value.kind)
            let key = VocabularyPolicy.entryKey(capture)
            let index: Int
            if let found = indices[key] { index = found } else {
                index = entries.count
                indices[key] = index
                if value.language == nil, plan.document.schemaVersion == 3 { plan.document.schemaVersion = 4 }
                entries.append(VocabularyEntry(id: UUID(), expression: value.expression,
                    dictionaryForm: value.dictionaryForm, language: value.language, kind: value.kind,
                    senses: [], createdAt: now, updatedAt: now))
                plan.result.addedEntries += 1
            }
            if keys[index] == nil { keys[index] = EntryIndex(entries[index]) }
            let candidate = SenseKey(meaning: VocabularyPolicy.normalized(value.meaning),
                language: value.meaning.isEmpty ? nil : value.meaningLanguage, note: value.note, tags: value.tags)
            let bareWord = value.meaning.isEmpty && value.note.isEmpty && value.tags.isEmpty
            let matching = keys[index]?.senses[candidate] ?? []
            if let example = VocabularyImportedExamplePolicy.example(value, now: now) {
                let existing = keys[index]?.examples[VocabularyPolicy.exampleKey(example)]
                // Mutate the plan's entry directly. Holding a copied entry here would force
                // Swift's copy-on-write arrays to copy every earlier example on every CSV row.
                let change = try VocabularyImportedExamplePolicy.append(value, example: example, to: &entries[index],
                    lookup: .init(matching: matching, existing: existing), now: now)
                plan.record(change, entryID: entries[index].id)
                plan.collect(senseID: change.senseID,
                    interpretationID: entries[index].senses[change.location.sense].examples[change.location.example].id)
                keys[index]?.record(change, key: VocabularyPolicy.exampleKey(example), entry: entries[index])
                continue
            }
            let entry = entries[index]
            if !entry.senses.isEmpty, bareWord || !matching.isEmpty {
                plan.collect(senseID: entry.senses[matching.first ?? 0].id)
                plan.result.skippedRows += 1
                if plan.result.selection == nil {
                    plan.result.selection = .init(entryID: entry.id, senseID: entry.senses[matching.first ?? 0].id)
                }
                continue
            }
            // Explicit senses are not the single context-free capture slot used by favorite
            // buttons. This preserves independent imported meanings and the existing graph invariant.
            let sense = VocabularySense(id: UUID(), meaning: value.meaning, meaningLanguage: value.meaningLanguage,
                meaningOrigin: value.meaning.isEmpty ? .captured : .user, note: value.note, tags: value.tags,
                createdAt: now, updatedAt: now, createdWithoutContext: true)
            entries[index].senses.append(sense)
            entries[index].updatedAt = now
            keys[index]?.include(sense, at: entry.senses.count)
            let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
            if !plan.result.hasChanges { plan.result.selection = selection }
            plan.result.addedSenses += 1
        }
        plan.document.entries = entries
        plan.applyCollections(now: now)
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
