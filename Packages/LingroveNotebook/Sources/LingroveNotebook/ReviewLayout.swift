import Foundation

/// A card owns an ordered pair of layouts. Parts either follow notebook content by stable ID
/// or own card-only rich content. The same value feeds the editor, preview, backup and Anki.
public nonisolated struct ReviewLayout: Codable, Equatable, Sendable {
    public var front: [ReviewCardPart] = []
    public var back: [ReviewCardPart] = []
    public var parts: [ReviewCardPart] { front + back }
    public var customContent: [VocabularyContentBlock] { parts.flatMap(\.content) }
    public var audioKinds: Set<ReviewAudioKind> {
        Set(parts.compactMap { part in
            switch part.source {
            case .expressionAudio: .expression
            case .sentenceAudio: .sentence
            default: nil
            }
        })
    }

    public init(
        front: [ReviewCardPart] = [],
        back: [ReviewCardPart] = []
    ) {
        self.front = front
        self.back = back
    }
}

/// References never infer an image from its caption or an example from array position. A nil
/// block ID is a template slot awaiting a concrete selection when applied to another sense.
public nonisolated struct ReviewCardPart: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var source: ReviewContentSource
    public var blockID: UUID?
    public var showCaption = false
    public var content: [VocabularyContentBlock] = []

    public init(
        id: UUID = UUID(),
        source: ReviewContentSource,
        blockID: UUID? = nil,
        showCaption: Bool = false,
        content: [VocabularyContentBlock] = []
    ) {
        self.id = id
        self.source = source
        self.blockID = blockID
        self.showCaption = showCaption
        self.content = content
    }
}

public nonisolated enum ReviewContentSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case expression, meaning, sentence, translation, contextualMeaning, explanation, notes, gapSentence
    case senseText, senseImage, expressionAudio, sentenceAudio, custom
    public var id: String { rawValue }
}

/// Templates are reusable layouts, not remote Anki note types. Each application creates fresh
/// part IDs and binds source slots to the destination sense; existing cards remain independent.
public nonisolated struct ReviewLayoutTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var layout: ReviewLayout

    public init(
        id: UUID = UUID(),
        name: String,
        layout: ReviewLayout
    ) {
        self.id = id
        self.name = name
        self.layout = layout
    }
}
