import Foundation

/// A card owns an ordered pair of layouts. Parts either follow notebook content by stable ID
/// or own card-only rich content. The same value feeds the editor, preview, backup and Anki.
nonisolated struct ReviewLayout: Codable, Equatable, Sendable {
    var front: [ReviewCardPart] = []
    var back: [ReviewCardPart] = []
    var parts: [ReviewCardPart] { front + back }
    var customContent: [VocabularyContentBlock] { parts.flatMap(\.content) }
    var audioKinds: Set<ReviewAudioKind> {
        Set(parts.compactMap { part in
            switch part.source {
            case .expressionAudio: .expression
            case .sentenceAudio: .sentence
            default: nil
            }
        })
    }
}

/// References never infer an image from its caption or an example from array position. A nil
/// block ID is a template slot awaiting a concrete selection when applied to another sense.
nonisolated struct ReviewCardPart: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var source: ReviewContentSource
    var blockID: UUID?
    var showCaption = false
    var content: [VocabularyContentBlock] = []
}

nonisolated enum ReviewContentSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case expression, meaning, sentence, translation, contextualMeaning, explanation, notes, gapSentence
    case senseText, senseImage, expressionAudio, sentenceAudio, custom
    var id: String { rawValue }
    var label: String {
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

/// Templates are reusable layouts, not remote Anki note types. Each application creates fresh
/// part IDs and binds source slots to the destination sense; existing cards remain independent.
nonisolated struct ReviewLayoutTemplate: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var layout: ReviewLayout
}

/// Resolved material contains no source IDs, so equality measures only what will be exported.
/// Audio remains typed until serialization, avoiding unsafe placeholder replacement in user text.
nonisolated enum ReviewResolvedPart: Equatable, Sendable {
    case text(String), blocks([VocabularyContentBlock]), audio(ReviewAudioKind)
}

extension VocabularySense {
    /// All accepted layouts participate in the media graph, even retained plans hidden from
    /// the current UI. Backups must never depend on which editor presently exposes a value.
    var reviewLayouts: [ReviewLayout] {
        ([review].compactMap { $0 } + (reviewCards ?? [])).flatMap {
            ([$0.plan] + $0.preservedPlans).compactMap(\.layout)
        }
    }

    func reviewValue(_ cardID: UUID?) -> VocabularyReview? {
        guard let cardID else { return review }
        return reviewCards?.first { $0.plan.id == cardID }
    }

    mutating func setReview(_ value: VocabularyReview, cardID: UUID?) {
        guard let cardID else { review = value; return }
        if let index = reviewCards?.firstIndex(where: { $0.plan.id == cardID }) { reviewCards?[index] = value } else {
            if reviewCards == nil { reviewCards = [] }
            reviewCards?.append(value)
        }
    }
}
