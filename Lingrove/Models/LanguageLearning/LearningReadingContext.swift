import Foundation

/// Evidence belongs to the in-memory reading session, not to a saved vocabulary example.
/// Readers supply bounded windows; the pure policy validates and ranks them. A host's
/// sentence/paragraph API alone is not proof that its range crossed inline formatting nodes.
nonisolated struct LearningReadingWindow: Equatable, Sendable {
    enum Boundary: String, Sendable {
        case container, layoutBlock, sentence, crop, unknown, deadline
        var isComplete: Bool { self == .container || self == .sentence }
    }
    enum Method: String, Sendable {
        case characters, block, paragraph, sentence, markerWindow, markerWalk, ocr, selectionOCR
    }
    let text: String
    let target: NSRange
    let left: Boundary
    let right: Boundary
    let method: Method
    /// OCR confidence is diagnostic evidence, not a comparable score for exact AX text.
    var confidence: Float?
}

/// One validated occurrence and its enclosing sentence(s). The acquisition window is retained
/// for diagnostics and language evidence; only `text` becomes the card's translated original.
/// This value lives with the reading receipt. It owns no AX handles, model work or persistence.
nonisolated struct LearningReadingContext: Equatable, Sendable {
    let window: LearningReadingWindow
    let scope: NSRange
    let target: NSRange
    let left: LearningReadingWindow.Boundary
    let right: LearningReadingWindow.Boundary
    let sentenceCount: Int
    let languageHint: LearningLanguage?

    var text: String { (window.text as NSString).substring(with: scope) }
    var isComplete: Bool { left.isComplete && right.isComplete }
    /// A layout block helps choose translation vs lookup when the user selected the whole
    /// material. It does not certify linguistic completeness for the model's context field.
    var hasBlockCoverage: Bool {
        window.method == .block && window.left == .layoutBlock && window.right == .layoutBlock
    }
    var selectionCoversContext: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) ==
            (text as NSString).substring(with: target).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Persistence and the shared card still consume their established example type. Keeping
    /// this conversion at the consumer seam prevents acquisition evidence leaking into archives.
    func example(app: String, id: UUID = UUID(), createdAt: Date = Date()) -> VocabularyExample {
        VocabularyExample(id: id, text: text, translation: "", ranges: [VocabularyTextRange(target)],
            completeness: isComplete && sentenceCount == 1 ? .sentence : .fragment,
            meaning: "", appBundleIdentifier: app, createdAt: createdAt)
    }
}
