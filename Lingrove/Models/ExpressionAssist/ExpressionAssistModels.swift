import Combine
import CoreGraphics
import Foundation

/// A request contains only explicitly requested intent and bounded neighboring text. Editor
/// handles live in the editor session, never in this value or a model/network payload.
nonisolated struct ExpressionAssistRequest: Equatable, Sendable, Encodable {
    let query: String
    let leftContext: String
    let rightContext: String
    let selectedText: String
    let targetLanguage: String
    let explanationLanguage: String
}

/// One complete, validated insertion choice. The dictionary form preserves a reusable expression
/// independently of the inflected text that fits this particular sentence.
nonisolated struct ExpressionAssistCandidate: Equatable, Sendable, Decodable {
    let text: String
    let hint: String
    var dictionaryForm: String?
}

/// Ambiguity is a normal result, not a transport failure. The coordinator displays a short question
/// in the same input surface; it never inserts explanatory prose into the host document.
nonisolated struct ExpressionAssistResult: Equatable, Sendable, Decodable {
    let candidates: [ExpressionAssistCandidate]
    var clarification: String?
}

/// The app graph owns the generator and panel once; each coordinator session borrows them. Narrow
/// contracts let cancellation and stale-result tests use delayed responses without real windows.
@MainActor
protocol ExpressionAssistGenerating: AnyObject {
    func generate(_ request: ExpressionAssistRequest, requestID: String) async throws -> ExpressionAssistResult
    func recordDisplay(requestID: String)
}

@MainActor
protocol ExpressionAssistPresenting: AnyObject {
    var isVisible: Bool { get }
    var hasKeyFocus: Bool { get }
    var onQueryChanged: ((String, Bool) -> Void)? { get set }
    var onSubmit: (() -> Void)? { get set }
    var onAccept: ((ExpressionAssistCandidate) -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    var onDismissed: (() -> Void)? { get set }
    /// Presentation completes only after the application and the native text client own input.
    func show(context: FocusedInputSnapshot, trigger: String, initialQuery: String) async
    func update(result: ExpressionAssistResult?, message: String?, loading: Bool)
    func update(result: ExpressionAssistResult?, message: String?, loading: Bool, request: ExpressionAssistRequest?)
    func hide(restoringHost: Bool)
    func showFailure(context: FocusedInputSnapshot, text: String, message: String)
}

extension ExpressionAssistPresenting {
    func update(result: ExpressionAssistResult?, message: String?, loading: Bool, request: ExpressionAssistRequest?) {
        update(result: result, message: message, loading: loading)
    }
}

/// The coordinator owns one saved capture per invocation. The production adapter retains its AX
/// element through ARC and rebases only the explicitly owned panel focus round trip.
@MainActor
protocol ExpressionAssistEditing: AnyObject {
    func capture(trigger: String?) throws -> LearningSelectionCapture
    func isUnchanged(_ saved: LearningSelectionCapture) -> Bool
    func resume(_ saved: LearningSelectionCapture) throws -> LearningSelectionCapture
    func replace(_ saved: LearningSelectionCapture, text: String) async throws
}
