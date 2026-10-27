import CoreGraphics
import Foundation

/// Acquisition is independent of translation. The coordinator uses this value for eligibility,
/// shortcut routing and diagnostics; no source grants permission to replace text in another app.
nonisolated enum LearningReadingSource: String, CaseIterable, Sendable {
    case selection, pointer, screenshot

    var title: String {
        switch self {
        case .selection: String(localized: "Translate selected text", table: "Learning")
        case .pointer: String(localized: "Translate text under pointer", table: "Learning")
        case .screenshot: String(localized: "Translate screen region", table: "Learning")
        }
    }
}

/// Memory-only read receipt. It has no editing range or write handle: a reader keeps the AX
/// evidence privately, while the coordinator passes only its immutable text to the shared model.
nonisolated struct LearningReadingSelection: Equatable, Sendable {
    let id: UUID
    let text: String
    let processIdentifier: Int32
    let bundleIdentifier: String
    let anchor: CGRect
    var source: LearningReadingSource = .selection
    var languageHint: LearningLanguage?
    /// Bounded context captured with the target; contextual lookup interprets it with the selected unit.
    var context: LearningReadingContext?
    var traceID: String?
    var capturedAt = Date()
    /// Real AX text geometry only. The card's mouse-position fallback anchor is presentation,
    /// not evidence that an OCR occurrence belongs to this explicit selection.
    var selectionBounds: CGRect?
    /// An external selection gesture frozen with this exact AX receipt. It can locate OCR when
    /// range geometry is unavailable; the presentation anchor is never promoted into evidence.
    var gesture: LearningReadingGesture?
    var vocabularyContext: VocabularyExample? { context?.example(app: bundleIdentifier, id: id, createdAt: capturedAt) }
}

/// Memory-only pointer evidence attached by the reading coordinator immediately after capture.
/// The receipt ID prevents reusing an old drag for a later selection with identical spelling.
/// The source reader validates it before capture; OCR uses its endpoints only for occurrence
/// alignment. It owns no event monitor, image or native handle and expires with the receipt.
nonisolated struct LearningReadingGesture: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case drag, doubleClick }
    let selectionID: UUID
    let start: CGPoint
    let end: CGPoint
    let kind: Kind
    let completedAt: Date
}

/// The app environment owns one reader. This narrow seam lets lifecycle tests change a selection
/// without making real cross-process AX calls or touching the user's clipboard.
@MainActor
protocol LearningReadingSelecting: AnyObject {
    func capture() async throws -> LearningReadingSelection
    func capture(source: LearningReadingSource) async throws -> LearningReadingSelection
    func enrich(_ capture: LearningReadingSelection) async throws -> LearningReadingSelection
    var isSelectingRegion: Bool { get }
    func isCurrent(_ capture: LearningReadingSelection) -> Bool
    func forget()
    func setInvalidationHandler(_ handler: (@MainActor () -> Void)?)
}

extension LearningReadingSelecting {
    func enrich(_ capture: LearningReadingSelection) async throws -> LearningReadingSelection { capture }
    var isSelectingRegion: Bool { false }
    func capture(source: LearningReadingSource) async throws -> LearningReadingSelection {
        guard source == .selection else { throw CancellationError() }
        return try await capture()
    }
    func setInvalidationHandler(_ handler: (@MainActor () -> Void)?) {}
}
