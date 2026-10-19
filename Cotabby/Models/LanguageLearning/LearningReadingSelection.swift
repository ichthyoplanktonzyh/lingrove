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
    var languageHint: LearningLanguage? = nil
}

/// The app environment owns one reader. This narrow seam lets lifecycle tests change a selection
/// without making real cross-process AX calls or touching the user's clipboard.
@MainActor
protocol LearningReadingSelecting: AnyObject {
    func capture() async throws -> LearningReadingSelection
    func capture(source: LearningReadingSource) async throws -> LearningReadingSelection
    var isSelectingRegion: Bool { get }
    func isCurrent(_ capture: LearningReadingSelection) -> Bool
    func forget()
    func setInvalidationHandler(_ handler: (@MainActor () -> Void)?)
}

extension LearningReadingSelecting {
    var isSelectingRegion: Bool { false }
    func capture(source: LearningReadingSource) async throws -> LearningReadingSelection {
        guard source == .selection else { throw CancellationError() }
        return try await capture()
    }
    func setInvalidationHandler(_ handler: (@MainActor () -> Void)?) {}
}
