import Foundation

/// Detached editors and archive transactions use one merge/move rule. Stable aliases retain
/// historical review ownership; source evidence and tool memory remain independently owned.
public nonisolated enum VocabularySenseEditingPolicy {
    public static func merge(source: UUID, into target: UUID, in entry: inout VocabularyEntry, now: Date) throws {
        guard let from = entry.senses.firstIndex(where: { $0.id == source }),
              let to = entry.senses.firstIndex(where: { $0.id == target }), from != to else {
            throw VocabularyError.invalidContent
        }
        guard Set((entry.senses[from].examples + entry.senses[to].examples).map {
            VocabularyIdentityPolicy.exampleKey($0)
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
        if original.createdWithoutContext == true { merged.createdWithoutContext = true }
        merged.explanations += original.explanations.filter { record in !merged.explanations.contains { $0.id == record.id } }
        merged.mergedFrom += [original.id] + original.mergedFrom
        merged.explanations = reboundGeneralExplanations(merged.explanations, entry: entry, sense: merged)
        merged.reviewCards = (merged.reviewCards ?? []) + (original.reviewCards ?? [])
        merged.review = mergedReview(merged.review, original.review)
        merged.updatedAt = now
        entry.senses[to] = merged
        entry.senses.remove(at: from)
        entry.updatedAt = now
    }

    /// Explicit merge transfers ownership. Rebind only a known local general-meaning receipt;
    /// model input text, record UUID, timestamps and answers stay intact. A legacy favorite
    /// retains its nil receipt so future floating captures still reach that unique slot.
    private static func reboundGeneralExplanations(
        _ records: [LearningExplanationRecord], entry: VocabularyEntry, sense: VocabularySense
    ) -> [LearningExplanationRecord] {
        let expected = VocabularyExplanationIdentity.input(for: entry, sense: sense, example: nil)
        let aliases = Set(([sense.id] + sense.mergedFrom).map { "sense:" + $0.uuidString })
        return records.map { record in
            guard record.input.contextKind == .none,
                  record.input.occurrenceIdentity == nil || aliases.contains(record.input.occurrenceIdentity ?? "") else { return record }
            let old = record.input
            let input = LearningExplanationInput(target: old.target, dictionaryForm: old.dictionaryForm,
                language: old.language, kind: old.kind, context: old.context, ranges: old.ranges,
                contextKind: old.contextKind, occurrenceIdentity: expected.occurrenceIdentity)
            guard input == expected else { return record }
            return .init(id: record.id, input: input, language: record.language, result: record.result,
                model: record.model, createdAt: record.createdAt)
        }
    }

    public static func move(exampleID: UUID, from source: UUID, to target: UUID?, in entry: inout VocabularyEntry, now: Date) throws -> UUID {
        guard let from = entry.senses.firstIndex(where: { $0.id == source }),
              let usage = entry.senses[from].examples.first(where: { $0.id == exampleID }) else {
            throw VocabularyError.editConflict
        }
        let targetID: UUID
        if let target {
            guard let to = entry.senses.firstIndex(where: { $0.id == target }), to != from else { throw VocabularyError.invalidContent }
            guard !entry.senses[to].examples.contains(where: {
                VocabularyIdentityPolicy.exampleKey($0) == VocabularyIdentityPolicy.exampleKey(usage)
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

    private static func mergedReview(_ target: VocabularyReview?, _ source: VocabularyReview?) -> VocabularyReview? {
        guard var result = target ?? source else { return nil }
        guard let target, let source else { return result }
        result = target
        for binding in source.bindings where !result.bindings.contains(where: {
            $0.endpoint == binding.endpoint && $0.profile == binding.profile &&
                ($0.noteID != nil && $0.noteID == binding.noteID || $0.originSenseID == binding.originSenseID)
        }) { result.bindings.append(binding) }
        result.preservedPlans += [source.plan] + source.preservedPlans
        if result.bindings.count > 1 { result.activeBindingID = nil } else { result.activeBindingID = result.bindings.first?.id }
        return result
    }
}
