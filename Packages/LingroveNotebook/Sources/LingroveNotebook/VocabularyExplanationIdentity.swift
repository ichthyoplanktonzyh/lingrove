import Foundation

/// Saved explanations belong to an exact input, not to whichever model happens to be configured.
/// This stateless constructor serves both the Mac capture adapter and notebook validation. A
/// mobile reader needs only saved values and can identify stale records without a generation service.
public nonisolated enum VocabularyExplanationIdentity {
    public static func input(
        expression: String, dictionaryForm: String, language: LearningLanguage?, kind: VocabularyEntry.Kind,
        example: VocabularyExample?, generalIdentity: String? = nil
    ) -> LearningExplanationInput {
        .init(target: expression, dictionaryForm: dictionaryForm, language: language, kind: kind,
            context: example?.text ?? expression,
            ranges: example?.ranges ?? [.init(NSRange(location: 0, length: expression.utf16.count))],
            contextKind: example.map {
                switch $0.completeness {
                case .sentence: .sentence
                case .fragment: .fragment
                case .unknown: .unknown
                }
            } ?? .none,
            occurrenceIdentity: example.map(VocabularyIdentityPolicy.exampleKey) ?? generalIdentity)
    }

    public static func input(
        for entry: VocabularyEntry, sense: VocabularySense? = nil, example: VocabularyExample?
    ) -> LearningExplanationInput {
        let owner = sense ?? entry.senses.first { candidate in
            if let example { return candidate.examples.contains { $0.id == example.id } }
            return candidate.isSavedWithoutContext
        }
        return input(expression: entry.expression, dictionaryForm: entry.dictionaryForm, language: entry.language,
            kind: entry.kind, example: example, generalIdentity: generalIdentity(for: owner))
    }

    /// A manually created sense can have a context-free explanation before it takes the
    /// personal collection's general-favorite slot. Preserve its existing case-sensitive UUID key.
    public static func generalIdentity(for sense: VocabularySense?) -> String? {
        sense.flatMap { $0.createdWithoutContext == true && !$0.isSavedWithoutContext ? "sense:" + $0.id.uuidString : nil }
    }
}
