import Foundation
import NaturalLanguage

/// Reading has no configured source direction: the coordinator resolves each immutable receipt
/// before opening either translation or lookup. Keeping this policy separate from writing avoids
/// turning the user's writing-language preferences into guesses about a document they are reading.
nonisolated enum LearningReadingLanguageResolver {
    /// A short-lived decision also carries its evidence for diagnostics without logging the text.
    /// A confident language outside the supported palette keeps its evidence but has no language.
    struct Resolution: Equatable {
        let language: LearningLanguage?
        let evidence: Evidence
    }

    /// Stable diagnostic labels describe which part of the receipt supplied the decision.
    enum Evidence: String {
        case selection, context, hint, unavailable
    }

    static func resolve(
        text: String, context: String? = nil, hint: LearningLanguage? = nil,
        recognize: (String) -> [NLLanguage: Double] = hypotheses
    ) -> Resolution {
        let sample = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        guard sample.contains(where: \.isLetter) else { return .init(language: nil, evidence: .unavailable) }
        // A sentence in another language can occur inside a document. Its own strong evidence
        // wins, but a shared Latin word such as “focus” or “chat” must first borrow its sentence.
        let selected = confidentLanguage(in: sample, recognize: recognize)
        if hasEnoughIndependentEvidence(sample), let selected {
            return resolution(selected, evidence: .selection)
        }
        if let context {
            let surrounding = String(context.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            if surrounding != sample, let detected = confidentLanguage(in: surrounding, recognize: recognize) {
                if isCompatible(sample, with: detected) { return resolution(detected, evidence: .context) }
            }
        }
        // Pointer capture may already have recognized a wider AX/OCR span. A Latin word inside
        // Chinese prose must not become Chinese merely because that wider span supplied a hint.
        if let hint, isCompatible(sample, with: hint.naturalLanguage) { return .init(language: hint, evidence: .hint) }
        if let selected { return resolution(selected, evidence: .selection) }
        return .init(language: nil, evidence: .unavailable)
    }

    private static func resolution(_ language: NLLanguage, evidence: Evidence) -> Resolution {
        .init(language: LearningLanguage(rawValue: language.rawValue), evidence: evidence)
    }

    private static func hasEnoughIndependentEvidence(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let words = text.split(whereSeparator: { !$0.isLetter }).count
        let hasNonLatinLetters = text.range(of: "(?!\\p{Latin})\\p{L}", options: .regularExpression) != nil
        return letters.count >= 8 && (words >= 3 || hasNonLatinLetters)
    }

    private static func isCompatible(_ text: String, with language: NLLanguage) -> Bool {
        // Keep the raw detected language until after this check: unsupported Latin prose must
        // still allow a short Chinese/Japanese quote to use its own independently detected language.
        guard language != .undetermined,
              let script = Locale.Language(identifier: language.rawValue).script?.identifier else { return false }
        let pattern: String
        switch script {
        case "Hans", "Hant": pattern = "\\p{Han}"
        case "Jpan": pattern = "[\\p{Han}\\p{Hiragana}\\p{Katakana}]"
        case "Kore": pattern = "[\\p{Hangul}\\p{Han}]"
        default: pattern = "\\p{\(script)}"
        }
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func confidentLanguage(
        in text: String, recognize: (String) -> [NLLanguage: Double]
    ) -> NLLanguage? {
        let ranked = recognize(text).filter { $0.value.isFinite && (0...1).contains($0.value) }
            .sorted { $0.value > $1.value }
        guard let first = ranked.first, first.value >= 0.55,
              ranked.count == 1 || first.value - ranked[1].value >= 0.15 else { return nil }
        return first.key
    }

    private static func hypotheses(_ sample: String) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        // Constraining recognition to our palette would silently relabel unsupported languages.
        recognizer.processString(sample)
        return recognizer.languageHypotheses(withMaximum: 3)
    }
}
