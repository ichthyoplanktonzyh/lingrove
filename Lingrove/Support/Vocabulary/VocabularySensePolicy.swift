import Foundation
import LingroveNotebook

/// Pure ownership rules for expression → sense → usage. The archive runs these inside one
/// transaction; cards never infer an identity from generated wording or ask a classifier.
nonisolated enum VocabularySensePolicy {
    static func index(_ id: UUID, in entry: VocabularyEntry) -> Int? {
        entry.senses.firstIndex { $0.id == id || $0.mergedFrom.contains(id) }
    }

    static func destination(_ capture: VocabularyCapture, in entry: VocabularyEntry) -> VocabularyExplanationDestination? {
        if let example = capture.example {
            let matches = usageDestinations(example, senseID: capture.senseID, in: entry)
            return matches.count == 1 ? matches.first : nil
        }
        let candidates = entry.senses.filter { sense in
            if let id = capture.senseID, sense.id != id && !sense.mergedFrom.contains(id) { return false }
            return sense.isSavedWithoutContext
        }
        // Ambiguous explicit duplicates stay separate. Never choose a sense by ordering or by
        // similarity of its label; a notebook operation can supply an exact destination instead.
        guard candidates.count == 1, let sense = candidates.first else { return nil }
        return .init(entryID: entry.id, senseID: sense.id, exampleID: nil)
    }

    /// Keep legacy identity keys intact, including explicitly distinct old examples. An unknown
    /// observation may reuse one exact text/range occurrence without splitting its sense merely
    /// because the old reader called it a fragment. Ambiguous legacy duplicates need a destination.
    private static func usageDestinations(_ example: VocabularyExample, senseID: UUID?, in entry: VocabularyEntry)
        -> [VocabularyExplanationDestination] {
        var exact: [VocabularyExplanationDestination] = [], compatible: [VocabularyExplanationDestination] = []
        for sense in entry.senses where senseID == nil || sense.id == senseID || sense.mergedFrom.contains(where: { $0 == senseID }) {
            for saved in sense.examples {
                let destination = VocabularyExplanationDestination(entryID: entry.id, senseID: sense.id, exampleID: saved.id)
                if VocabularyPolicy.exampleKey(saved) == VocabularyPolicy.exampleKey(example) {
                    exact.append(destination)
                } else if saved.completeness == .unknown || example.completeness == .unknown,
                          saved.text.utf16.elementsEqual(example.text.utf16), saved.ranges == example.ranges {
                    compatible.append(destination)
                }
            }
        }
        return exact.isEmpty ? compatible : exact
    }

    static func save(_ capture: VocabularyCapture, in entry: inout VocabularyEntry, now: Date) throws {
        let prior = try savingDestination(capture, in: entry)
        let senseIndex: Int
        if let id = capture.senseID {
            guard let found = index(id, in: entry) else { throw VocabularyError.invalidContent }
            senseIndex = found
        } else if let prior, let found = index(prior.senseID, in: entry) {
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
                $0.id == prior?.exampleID || VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(example)
            }) {
                mergeUsage(example, into: &entry.senses[senseIndex].examples[existing])
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

    private static func savingDestination(_ capture: VocabularyCapture, in entry: VocabularyEntry)
        throws -> VocabularyExplanationDestination? {
        let prior = destination(capture, in: entry)
        if let example = capture.example, prior == nil,
           usageDestinations(example, senseID: capture.senseID, in: entry).count > 1 { throw VocabularyError.editConflict }
        return prior
    }

    private static func mergeUsage(_ captured: VocabularyExample, into saved: inout VocabularyExample) {
        // An uncertain new capture cannot overwrite an existing explicit classification.
        if saved.completeness == .unknown { saved.completeness = captured.completeness }
        addTranslation(captured.translation, language: captured.translationLanguage, to: &saved)
    }

    static func merge(source: UUID, into target: UUID, in entry: inout VocabularyEntry, now: Date) throws {
        try VocabularySenseEditingPolicy.merge(source: source, into: target, in: &entry, now: now)
    }

    static func move(exampleID: UUID, from source: UUID, to target: UUID?, in entry: inout VocabularyEntry, now: Date) throws -> UUID {
        try VocabularySenseEditingPolicy.move(exampleID: exampleID, from: source, to: target, in: &entry, now: now)
    }

    private static func addTranslation(_ text: String, language: LearningLanguage?, to example: inout VocabularyExample) {
        guard !text.isEmpty else { return }
        let variant = VocabularyMeaning(text: text, language: language)
        if !example.translationVariants.contains(variant) { example.translationVariants.append(variant) }
        if example.translation.isEmpty { example.translation = text; example.translationLanguage = language }
    }
}

/// A label is a projection, never an identity or a semantic matching key. A contextual draft
/// can label an unnamed sense while its canonical summary remains explicitly editable.
extension VocabularySense {
    nonisolated var displayTitle: String {
        if !meaning.isEmpty { return meaning }
        for block in content ?? [] {
            if case let .text(value) = block.content, !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.text
            }
        }
        if let text = examples.first(where: { !$0.meaning.isEmpty })?.meaning { return text }
        if !VocabularyContentPolicy.images(content ?? []).isEmpty { return String(localized: "Image explanation", table: "Vocabulary") }
        return String(localized: "Meaning pending", table: "Vocabulary")
    }
}
