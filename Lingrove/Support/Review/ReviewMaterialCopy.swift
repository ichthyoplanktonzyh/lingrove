import Foundation
import LingroveNotebook

/// The shared resolver owns finite error identity; the Mac host owns translated, actionable
/// wording. This adapter keeps internal enum descriptions out of either tool's editor.
nonisolated enum ReviewMaterialCopy {
    static func message(_ error: ReviewMaterialError) -> String {
        switch error {
        case let .missingContent(source):
            String(localized: "Card content is missing. Choose its source again.", table: "Vocabulary") + " · " + source.label
        case .emptyFace: String(localized: "Add content to both sides of the card.", table: "Vocabulary")
        case let .missingAudio(kind): BuiltInReviewCopy.text("material.generateAudio") + " · " + kind.label
        }
    }
}
