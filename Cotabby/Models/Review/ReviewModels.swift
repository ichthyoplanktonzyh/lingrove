import Foundation

/// The notebook owns this optional extension of a sense. Plans are editable review material,
/// not dictionary meanings. Bindings retain remote identity and the last acknowledged fields;
/// neither regenerating an explanation nor merging senses may discard an Anki association.
nonisolated struct VocabularyReview: Codable, Equatable, Sendable {
    var plan: ReviewPlan
    var bindings: [AnkiNoteBinding] = []
    var activeBindingID: UUID?
    var preservedPlans: [ReviewPlan] = []

    var activeBinding: AnkiNoteBinding? { bindings.first { $0.id == activeBindingID } }
    var needsBindingChoice: Bool { !bindings.isEmpty && activeBinding == nil }
}

/// One explicit preparation draft follows a representative usage by UUID. A nil answer follows
/// the source; an edited answer is review-only. Overrides preserve Anki edits without changing
/// the source notebook. The sheet copies this value and commits it only on Save or Send.
nonisolated struct ReviewPlan: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var exampleID: UUID?
    var deck: String?
    var answer: String?
    var recognition = true
    var gap = false
    var includeNotes = false
    var includeExplanation = false
    var fieldOverrides: [String: String] = [:]
    /// Optional additions preserve old v3 archives. Audio is generated only by an explicit
    /// preparation/send action; the notebook stores receipts, never audio bytes or credentials.
    var audioKinds: Set<ReviewAudioKind>?
    var audioReceipts: [ReviewAudioKind: ReviewAudioReceipt]?
}

/// A remote receipt outlives window navigation. originSenseID stays unchanged after a merge so
/// retry recovery finds the same note, even when another retained note uses the survivor's ID.
nonisolated struct AnkiNoteBinding: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let originSenseID: UUID
    let endpoint: String
    let profile: String
    let noteID: Int64?
    let model: String
    var deck: String
    let identityField: String
    let mapping: [ReviewField: String]
    var fields: [String: String]
    var syncedAt: Date?
}

/// Plain review content is shared by SwiftUI preview and safe HTML serialization. Its equality
/// includes only exported material, so browsing dictionaries cannot make a note "out of date".
nonisolated struct ReviewCardContent: Equatable, Sendable {
    let expression: String
    let answer: String
    let sentence: String
    let ranges: [VocabularyTextRange]
    let translation: String
    let explanation: String
    let notes: String
    let gapPrompt: String
    let gapAnswer: String
    let recognition: Bool
    let gap: Bool
}

/// Logical fields remain independent of the user's Anki model. The preset owns a complete
/// mapping; a custom model explicitly maps these names to its existing fields.
nonisolated enum ReviewField: String, Codable, CaseIterable, Identifiable, Sendable {
    case identity = "LingroveID", expression = "Expression", meaning = "Meaning", sentence = "Sentence"
    case translation = "Translation", explanation = "Explanation", notes = "Notes"
    case recognition = "Recognition", gapPrompt = "GapPrompt", gapAnswer = "GapAnswer"
    case expressionAudio = "ExpressionAudio", sentenceAudio = "SentenceAudio"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .identity: String(localized: "Sense ID", table: "Vocabulary")
        case .expression: String(localized: "Expression", table: "Vocabulary")
        case .meaning: String(localized: "Review answer", table: "Vocabulary")
        case .sentence: String(localized: "Example sentence", table: "Vocabulary")
        case .translation: String(localized: "Translation", table: "Learning")
        case .explanation: String(localized: "AI explanation", table: "Learning")
        case .notes: String(localized: "Notes", table: "Vocabulary")
        case .recognition: String(localized: "Recognition card", table: "Vocabulary")
        case .gapPrompt: String(localized: "Gap question", table: "Vocabulary")
        case .gapAnswer: String(localized: "Gap answer", table: "Vocabulary")
        case .expressionAudio: String(localized: "Expression audio", table: "Vocabulary")
        case .sentenceAudio: String(localized: "Example audio", table: "Vocabulary")
        }
    }
}

/// Configuration is snapshotted before every operation. The application only permits loopback
/// endpoints; an API key exists in memory/Keychain, never in the notebook or diagnostic fields.
nonisolated struct AnkiConnection: Sendable, Equatable {
    let endpoint: URL
    let apiKey: String
}

/// A connection probe returns only navigation metadata. The controller publishes this transient
/// snapshot; it is never treated as proof of the active profile during a later write.
nonisolated struct AnkiReviewCatalog: Equatable, Sendable {
    let profile: String
    let decks: [String]
    let models: [String]
}

/// One verified server read supplies conflict comparison and acknowledgement checks. Sessions
/// retain it only while preparing an explicit write, independently of the durable receipt.
nonisolated struct AnkiRemoteNote: Equatable, Sendable {
    let id: Int64
    let model: String
    let fields: [String: String]
}

/// Field-level conflict information belongs to a sheet session, not durable learning content.
/// A failed update leaves the original receipt intact until a verified write is acknowledged.
nonisolated struct AnkiFieldConflict: Identifiable, Equatable, Sendable {
    let id: String
    let local: String
    let remote: String
}

nonisolated enum AnkiReviewError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
