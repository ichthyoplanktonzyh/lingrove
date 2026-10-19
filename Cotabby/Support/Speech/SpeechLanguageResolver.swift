import Foundation
import NaturalLanguage

/// Stateless policy shared by every speaker button through LearningSpeechController. It examines
/// bounded text only after an explicit click; views never run recognition while being rendered.
/// A fresh recognizer belongs to each call, so NaturalLanguage's mutable state is never shared.
nonisolated enum SpeechLanguageResolver {
    private static let maximumSampleLength = 600

    /// The actual phrase wins when there is enough evidence. Short words borrow their own
    /// sentence's language before falling back to the card hint. nil means a confidently detected
    /// language outside Lingrove's language palette, not an uncertain guess or provider fallback.
    static func resolve(
        text: String, hint: LearningLanguage, context: String? = nil,
        recognize: (String) -> [NLLanguage: Double] = hypotheses
    ) -> LearningLanguage? {
        if let language = confidentLanguage(in: text, recognize: recognize) {
            return LearningLanguage(rawValue: language.rawValue)
        }
        if let context, let language = confidentLanguage(in: context, recognize: recognize) {
            return LearningLanguage(rawValue: language.rawValue)
        }
        return hint
    }

    private static func confidentLanguage(
        in text: String, recognize: (String) -> [NLLanguage: Double]
    ) -> NLLanguage? {
        let sample = String(text.prefix(maximumSampleLength))
        guard hasEnoughEvidence(sample) else { return nil }
        // Do not constrain recognition to provider-supported languages: doing so would turn an
        // unsupported passage into a plausible but wrong supported language before validation.
        let ranked = recognize(sample).filter { $0.value.isFinite && (0...1).contains($0.value) }
            .sorted { $0.value > $1.value }
        guard let first = ranked.first, first.value >= 0.75,
              ranked.count == 1 || first.value - ranked[1].value >= 0.20 else { return nil }
        return first.key
    }

    private static func hasEnoughEvidence(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return false }
        // Latin words such as “chat”, names and abbreviations are shared across languages. Even
        // a high classifier score for one word must not override its sentence/card language.
        let hasNonLatinLetters = letters.contains { $0.value > 0x024F }
        let wordCount = text.split(whereSeparator: { !$0.isLetter }).count
        return letters.count >= 8 && (hasNonLatinLetters || wordCount >= 3)
    }

    private static func hypotheses(_ sample: String) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.languageHypotheses(withMaximum: 3)
    }
}
