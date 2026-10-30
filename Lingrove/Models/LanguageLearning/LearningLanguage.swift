import LingroveNotebook
import Foundation
import NaturalLanguage

/// Stable identifiers for translation settings, borrowing the original language palette's labels.
/// A language selects a direction and text-segmentation locale; it does not promise model support.
typealias LearningLanguage = LingroveNotebook.LearningLanguage

/// Recognition and host language labels stay outside the saved notebook graph.
extension LearningLanguage {
    nonisolated var name: String { LanguageCatalog.commonLanguages.first { $0.code == rawValue }?.name ?? rawValue }
    nonisolated var label: String { LanguageCatalog.commonLanguages.first { $0.code == rawValue }?.nativeLabel ?? rawValue }
    /// Cards need the native language name without the picker's bilingual explanation.
    /// Cache Foundation's names once so streamed previews do not repeat locale lookups.
    nonisolated var compactLabel: String { Self.compactLabels[self] ?? label }
    private nonisolated static let compactLabels = Dictionary(uniqueKeysWithValues: allCases.map { language in
        (language, Locale(identifier: language.rawValue).localizedString(forIdentifier: language.rawValue) ?? language.label)
    })
    nonisolated var naturalLanguage: NLLanguage { self == .chinese ? .simplifiedChinese : NLLanguage(rawValue: rawValue) }

    /// Only recent committed text is inspected. An uncertain result leaves the configured source
    /// language unavailable rather than guessing which translation direction to use.
    nonisolated static func detect(in text: String) -> Self? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(600)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
        guard let first = hypotheses.first, first.value >= 0.55,
              hypotheses.count == 1 || first.value - hypotheses[1].value >= 0.15 else { return nil }
        if first.key == .traditionalChinese { return .traditionalChinese }
        if first.key == .simplifiedChinese { return .chinese }
        return Self(rawValue: first.key.rawValue)
    }
}

/// An operation captures its languages before awaiting the model so later setting edits cannot
/// relabel or commit an old reply.
nonisolated enum LearningExpressionTask: Equatable, Sendable {
    case translation(source: LearningLanguage?, target: LearningLanguage)

    var target: LearningLanguage {
        switch self {
        case .translation(_, let target): target
        }
    }
}
