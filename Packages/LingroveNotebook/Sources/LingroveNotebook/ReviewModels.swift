import Foundation

/// The notebook owns this optional extension of a sense. Plans are editable review material,
/// not dictionary meanings. Bindings retain remote identity and the last acknowledged fields;
/// neither regenerating an explanation nor merging senses may discard an Anki association.
public nonisolated struct VocabularyReview: Codable, Equatable, Sendable {
    public var plan: ReviewPlan
    public var bindings: [AnkiNoteBinding] = []
    public var activeBindingID: UUID?
    public var preservedPlans: [ReviewPlan] = []

    public var activeBinding: AnkiNoteBinding? { bindings.first { $0.id == activeBindingID } }
    public var needsBindingChoice: Bool { !bindings.isEmpty && activeBinding == nil }

    public init(
        plan: ReviewPlan,
        bindings: [AnkiNoteBinding] = [],
        activeBindingID: UUID? = nil,
        preservedPlans: [ReviewPlan] = []
    ) {
        self.plan = plan
        self.bindings = bindings
        self.activeBindingID = activeBindingID
        self.preservedPlans = preservedPlans
    }
}

/// One explicit preparation draft follows a representative usage by UUID. A nil answer follows
/// the source; an edited answer is review-only. Overrides preserve Anki edits without changing
/// the source notebook. The sheet copies this value and commits it only on Save or Send.
public nonisolated struct ReviewPlan: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String?
    public var layout: ReviewLayout?
    public var exampleID: UUID?
    public var deck: String?
    public var answer: String?
    public var recognition = true
    public var gap = false
    public var includeNotes = false
    public var includeExplanation = false
    public var includeSenseContent: Bool?
    public var fieldOverrides: [String: String] = [:]
    /// Optional additions preserve old v3 archives. Audio is generated only by an explicit
    /// preparation/send action; the notebook stores receipts, never audio bytes or credentials.
    public var audioKinds: Set<ReviewAudioKind>?
    public var audioReceipts: [ReviewAudioKind: ReviewAudioReceipt]?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        layout: ReviewLayout? = nil,
        exampleID: UUID? = nil,
        deck: String? = nil,
        answer: String? = nil,
        recognition: Bool = true,
        gap: Bool = false,
        includeNotes: Bool = false,
        includeExplanation: Bool = false,
        includeSenseContent: Bool? = nil,
        fieldOverrides: [String: String] = [:],
        audioKinds: Set<ReviewAudioKind>? = nil,
        audioReceipts: [ReviewAudioKind: ReviewAudioReceipt]? = nil
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.exampleID = exampleID
        self.deck = deck
        self.answer = answer
        self.recognition = recognition
        self.gap = gap
        self.includeNotes = includeNotes
        self.includeExplanation = includeExplanation
        self.includeSenseContent = includeSenseContent
        self.fieldOverrides = fieldOverrides
        self.audioKinds = audioKinds
        self.audioReceipts = audioReceipts
    }
}

/// A remote receipt outlives window navigation. originSenseID stays unchanged after a merge so
/// retry recovery finds the same note, even when another retained note uses the survivor's ID.
public nonisolated struct AnkiNoteBinding: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public let originSenseID: UUID
    public let endpoint: String
    public let profile: String
    public let noteID: Int64?
    public let model: String
    public var deck: String
    public let identityField: String
    public let mapping: [ReviewField: String]
    public var fields: [String: String]
    public var syncedAt: Date?

    public init(
        id: UUID = UUID(),
        originSenseID: UUID,
        endpoint: String,
        profile: String,
        noteID: Int64?,
        model: String,
        deck: String,
        identityField: String,
        mapping: [ReviewField: String],
        fields: [String: String],
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.originSenseID = originSenseID
        self.endpoint = endpoint
        self.profile = profile
        self.noteID = noteID
        self.model = model
        self.deck = deck
        self.identityField = identityField
        self.mapping = mapping
        self.fields = fields
        self.syncedAt = syncedAt
    }
}

/// Logical fields remain independent of the user's Anki model. The preset owns a complete
/// mapping; a custom model explicitly maps these names to its existing fields.
public nonisolated enum ReviewField: String, Codable, CaseIterable, Identifiable, Sendable {
    case identity = "LingroveID", expression = "Expression", meaning = "Meaning", sentence = "Sentence"
    case translation = "Translation", explanation = "Explanation", notes = "Notes"
    case recognition = "Recognition", gapPrompt = "GapPrompt", gapAnswer = "GapAnswer"
    case expressionAudio = "ExpressionAudio", sentenceAudio = "SentenceAudio"
    public var id: String { rawValue }
}
