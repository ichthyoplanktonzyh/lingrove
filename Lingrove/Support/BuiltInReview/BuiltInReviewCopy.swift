import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// Review owns its small catalog so new Mac wording stays independent of optional Anki copy.
/// The host's ordinary bundle localization chooses the same fifteen supported UI languages.
nonisolated enum BuiltInReviewCopy {
    /// One gallery card's display copy, derived for the view without changing its preset.
    nonisolated struct PresetLabels {
        let title: String
        let subtitle: String
        let badge: String
    }

    private static let presets = ReviewNoteDefaults.presets

    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "BuiltInReview")
    }

    /// Localize shipped names at the UI boundary. The default has a stable ID; saved
    /// presets get fresh IDs, so match their shipped name and layout to preserve custom names.
    static func noteTypeName(_ type: ReviewNoteType) -> String {
        let bundled = ReviewNoteDefaults.type
        if type.id == bundled.id, type.name == bundled.name {
            return text("template.expressionAndContext")
        }
        if let preset = presets.first(where: { type.name == $0.title && ReviewNoteDefaults.matches($0, type: type) }) {
            return presetTitle(preset)
        }
        return type.name
    }

    static func presetLabels(_ preset: ReviewNoteDefaults.Preset) -> PresetLabels {
        let title = presetTitle(preset)
        guard preset.id == "editorial" else {
            return PresetLabels(title: title, subtitle: preset.subtitle, badge: preset.badge)
        }
        return PresetLabels(title: title, subtitle: text("preset.editorial.subtitle"), badge: String(localized: "Default"))
    }

    private static func presetTitle(_ preset: ReviewNoteDefaults.Preset) -> String {
        switch preset.id {
        case "editorial": text("preset.editorial.title")
        case "context-immersion": text("preset.contextImmersion.title")
        case "minimalist-swiss": text("preset.swissMinimalist.title")
        case "bilateral-recall": text("preset.bilateralRecall.title")
        default: preset.title
        }
    }

    static func cardTemplateName(_ template: ReviewCardTemplate) -> String {
        guard ReviewNoteDefaults.type.templates.contains(where: {
            $0.id == template.id && $0.name == template.name
        }) else { return template.name }
        return text("template.recognition")
    }

    static func status(_ status: LingroveNotebookReviewStatus) -> String {
        switch status {
        case .active: text("status.active")
        case .paused: text("status.paused")
        case .withdrawn: text("status.withdrawn")
        }
    }

    static func rating(_ rating: ReviewRating) -> String {
        switch rating {
        case .again: text("rating.again")
        case .hard: text("rating.hard")
        case .good: text("rating.good")
        case .easy: text("rating.easy")
        }
    }
}
