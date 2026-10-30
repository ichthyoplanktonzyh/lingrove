import LingroveNotebook
import Foundation

/// A card owns an ordered pair of layouts. Parts either follow notebook content by stable ID
/// or own card-only rich content. The same value feeds the editor, preview, backup and Anki.
typealias ReviewLayout = LingroveNotebook.ReviewLayout

/// References never infer an image from its caption or an example from array position. A nil
/// block ID is a template slot awaiting a concrete selection when applied to another sense.
typealias ReviewCardPart = LingroveNotebook.ReviewCardPart

typealias ReviewContentSource = LingroveNotebook.ReviewContentSource

/// Templates are reusable layouts, not remote Anki note types. Each application creates fresh
/// part IDs and binds source slots to the destination sense; existing cards remain independent.
typealias ReviewLayoutTemplate = LingroveNotebook.ReviewLayoutTemplate

/// Resolved material contains no source IDs, so equality measures only what will be exported.
/// Audio remains typed until serialization, avoiding unsafe placeholder replacement in user text.
nonisolated enum ReviewResolvedPart: Equatable, Sendable {
    case text(String), blocks([VocabularyContentBlock]), audio(ReviewAudioKind)
}

extension VocabularySense {
    nonisolated func reviewValue(_ cardID: UUID?) -> VocabularyReview? {
        guard let cardID else { return review }
        return reviewCards?.first { $0.plan.id == cardID }
    }

    nonisolated mutating func setReview(_ value: VocabularyReview, cardID: UUID?) {
        guard let cardID else { review = value; return }
        if let index = reviewCards?.firstIndex(where: { $0.plan.id == cardID }) { reviewCards?[index] = value } else {
            if reviewCards == nil { reviewCards = [] }
            reviewCards?.append(value)
        }
    }
}

/// The Mac host owns localized labels; shared review values carry stable field identities.
extension ReviewContentSource {
    nonisolated var label: String {
        switch self {
        case .expression: String(localized: "Expression", table: "Vocabulary")
        case .meaning: String(localized: "Core meaning", table: "Vocabulary")
        case .sentence: String(localized: "Example sentence", table: "Vocabulary")
        case .translation: String(localized: "Example translation", table: "Vocabulary")
        case .contextualMeaning: String(localized: "Contextual meaning", table: "Vocabulary")
        case .explanation: String(localized: "AI explanation", table: "Learning")
        case .notes: String(localized: "Notes", table: "Vocabulary")
        case .gapSentence: String(localized: "Gap question", table: "Vocabulary")
        case .senseText: String(localized: "Explanation text", table: "Vocabulary")
        case .senseImage: String(localized: "Explanation image", table: "Vocabulary")
        case .expressionAudio: ReviewAudioKind.expression.label
        case .sentenceAudio: ReviewAudioKind.sentence.label
        case .custom: String(localized: "Custom content", table: "Vocabulary")
        }
    }
}
