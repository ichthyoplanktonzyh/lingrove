import Foundation

/// Pure ownership rules for expression → sense → usage. The archive runs these inside one
/// transaction; cards never infer an identity from generated wording or ask a classifier.
nonisolated enum VocabularySensePolicy {
    static func index(_ id: UUID, in entry: VocabularyEntry) -> Int? {
        entry.senses.firstIndex { $0.id == id || $0.mergedFrom.contains(id) }
    }

    static func destination(_ capture: VocabularyCapture, in entry: VocabularyEntry) -> VocabularyExplanationDestination? {
        let candidates = entry.senses.filter { sense in
            if let id = capture.senseID, sense.id != id && !sense.mergedFrom.contains(id) { return false }
            if let example = capture.example {
                return sense.examples.contains { VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(example) }
            }
            return sense.isSavedWithoutContext
        }
        // Ambiguous explicit duplicates stay separate. Never choose a sense by ordering or by
        // similarity of its label; a notebook operation can supply an exact destination instead.
        guard candidates.count == 1, let sense = candidates.first else { return nil }
        let usage = capture.example.flatMap { example in
            sense.examples.first { VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(example) }
        }
        return .init(entryID: entry.id, senseID: sense.id, exampleID: usage?.id)
    }

    static func save(_ capture: VocabularyCapture, in entry: inout VocabularyEntry, now: Date) throws {
        let senseIndex: Int
        if let id = capture.senseID {
            guard let found = index(id, in: entry) else { throw VocabularyError.invalidContent }
            senseIndex = found
        } else if let destination = destination(capture, in: entry), let found = index(destination.senseID, in: entry) {
            senseIndex = found
        } else {
            // A new context is not evidence that its sense equals any existing one. Create a
            // stable identity silently and let explicit merge/move actions establish membership.
            entry.senses.append(VocabularySense(id: UUID(), meaning: capture.example == nil ? capture.meaning : "",
                meaningLanguage: capture.example == nil ? capture.meaningLanguage : nil, createdAt: now, updatedAt: now))
            senseIndex = entry.senses.count - 1
        }
        if var example = capture.example {
            guard !entry.senses.enumerated().contains(where: { index, sense in
                index != senseIndex && sense.examples.contains { VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(example) }
            }) else { throw VocabularyError.editConflict }
            if let existing = entry.senses[senseIndex].examples.firstIndex(where: {
                VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(example)
            }) {
                addTranslation(example.translation, language: example.translationLanguage,
                    to: &entry.senses[senseIndex].examples[existing])
            } else {
                if entry.examples.contains(where: { $0.id == example.id }) {
                    // One component receipt can yield several repeated-word occurrences. Only
                    // that new occurrence gets a new ID; moving it later never rewrites the ID.
                    example = example.copiedWithNewID()
                }
                addTranslation(example.translation, language: example.translationLanguage, to: &example)
                entry.senses[senseIndex].examples.append(example)
            }
        } else {
            guard !entry.senses.enumerated().contains(where: { $0.offset != senseIndex && $0.element.isSavedWithoutContext }) else {
                throw VocabularyError.editConflict
            }
            entry.senses[senseIndex].isSavedWithoutContext = true
            let meaning = VocabularyMeaning(text: capture.meaning, language: capture.meaningLanguage)
            if !entry.senses[senseIndex].standaloneMeanings.contains(meaning) {
                entry.senses[senseIndex].standaloneMeanings.append(meaning)
            }
        }
        entry.senses[senseIndex].updatedAt = now
        entry.updatedAt = now
        if let record = capture.explanation { VocabularyPolicy.storeExplanation(record, in: &entry) }
    }

    static func merge(source: UUID, into target: UUID, in entry: inout VocabularyEntry, now: Date) throws {
        guard let from = entry.senses.firstIndex(where: { $0.id == source }),
              let to = entry.senses.firstIndex(where: { $0.id == target }), from != to else {
            throw VocabularyError.invalidContent
        }
        guard Set((entry.senses[from].examples + entry.senses[to].examples).map {
            VocabularyPolicy.exampleKey($0)
        }).count == entry.senses[from].examples.count + entry.senses[to].examples.count else { throw VocabularyError.editConflict }
        let original = entry.senses[from]
        var merged = entry.senses[to]
        // Both sets of annotations survive. Choosing the destination chooses its displayed
        // core wording; the source's wording and identity remain in the exported sense record.
        if merged.meaning.isEmpty {
            merged.meaning = original.meaning; merged.meaningLanguage = original.meaningLanguage
            merged.meaningOrigin = original.meaningOrigin
        } else if !original.meaning.isEmpty && (original.meaning != merged.meaning || original.meaningLanguage != merged.meaningLanguage) {
            merged.alternateMeanings.append(.init(text: original.meaning, language: original.meaningLanguage))
        }
        merged.alternateMeanings += original.alternateMeanings
        if !original.note.isEmpty, original.note != merged.note {
            merged.note = [merged.note, original.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        merged.tags = Array(Set(merged.tags + original.tags)).sorted()
        merged.content = (merged.content ?? []) + (original.content ?? []).filter { block in
            !(merged.content ?? []).contains { $0.id == block.id }
        }
        merged.examples += original.examples
        merged.standaloneMeanings += original.standaloneMeanings.filter { !merged.standaloneMeanings.contains($0) }
        merged.isSavedWithoutContext = merged.isSavedWithoutContext || original.isSavedWithoutContext
        merged.explanations += original.explanations.filter { record in !merged.explanations.contains { $0.id == record.id } }
        merged.mergedFrom += [original.id] + original.mergedFrom
        merged.review = AnkiReviewPolicy.merged(merged.review, original.review)
        merged.updatedAt = now
        entry.senses[to] = merged
        entry.senses.remove(at: from)
        entry.updatedAt = now
    }

    static func move(exampleID: UUID, from source: UUID, to target: UUID?, in entry: inout VocabularyEntry, now: Date) throws -> UUID {
        guard let from = entry.senses.firstIndex(where: { $0.id == source }),
              let usage = entry.senses[from].examples.first(where: { $0.id == exampleID }) else {
            throw VocabularyError.editConflict
        }
        let targetID: UUID
        if let target {
            guard let to = entry.senses.firstIndex(where: { $0.id == target }), to != from else { throw VocabularyError.invalidContent }
            guard !entry.senses[to].examples.contains(where: {
                VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(usage)
            }) else { throw VocabularyError.editConflict }
            targetID = entry.senses[to].id
            entry.senses[to].examples.append(usage)
            entry.senses[to].updatedAt = now
        } else {
            let id = UUID(); targetID = id
            entry.senses.append(VocabularySense(id: id, meaning: "", examples: [usage], createdAt: now, updatedAt: now))
        }
        entry.senses[from].examples.removeAll { $0.id == exampleID }
        entry.senses[from].updatedAt = now
        // A sense can own notes or future review references even with no examples. Only an
        // explicit delete removes it; moving the last usage does not destroy its identity.
        entry.updatedAt = now
        return targetID
    }

    private static func addTranslation(_ text: String, language: LearningLanguage?, to example: inout VocabularyExample) {
        guard !text.isEmpty else { return }
        let variant = VocabularyMeaning(text: text, language: language)
        if !example.translationVariants.contains(variant) { example.translationVariants.append(variant) }
        if example.translation.isEmpty { example.translation = text; example.translationLanguage = language }
    }
}
