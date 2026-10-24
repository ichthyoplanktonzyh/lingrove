import CoreGraphics
import Foundation

/// The expression recorder checks every configured application, while dispatch checks only the
/// active one. It deliberately does not call the central conflict method, which includes this
/// command itself so existing shortcut recorders can detect reverse conflicts.
extension SuggestionSettingsModel {
    func expressionAssistShortcutConflict(keyCode: CGKeyCode, modifiers: ShortcutModifierMask,
                                          bundleIdentifier: String? = nil) -> String? {
        guard keyCode != Self.disabledKeyCode else { return nil }
        guard !modifiers.isEmpty, ![36, 76, 53].contains(keyCode) else {
            return String(localized: "Use a shortcut with a modifier key; Enter and Escape are reserved.", table: "Learning")
        }
        if let command = vocabularyShortcuts.command(key: UInt16(clamping: keyCode), modifiers: modifiers) { return command.title }
        if globalToggleKeyCode == keyCode, globalToggleKeyModifiers == modifiers { return ShortcutAction.toggleLingrove.displayName }
        let apps = bundleIdentifier.map { [$0] } ?? ([""] + perAppShortcutOverrides.map(\.bundleIdentifier))
        for app in apps {
            let word = resolvedAcceptBinding(forBundleIdentifier: app)
            let entire = resolvedFullAcceptBinding(forBundleIdentifier: app)
            if word.keyCode == keyCode, word.modifiers == modifiers { return ShortcutAction.acceptWord.displayName }
            if entire.keyCode == keyCode, entire.modifiers == modifiers { return ShortcutAction.acceptEntireSuggestion.displayName }
        }
        return expressionAssistTranslationConflict(keyCode: keyCode, modifiers: modifiers)
    }

    private func expressionAssistTranslationConflict(keyCode: CGKeyCode, modifiers: ShortcutModifierMask) -> String? {
        if languageLearning.translationEnabled {
            if (languageLearning.keyCode == keyCode && languageLearning.modifiers == modifiers) ||
                (languageLearning.replacementKeyCode == keyCode && languageLearning.replacementModifiers == modifiers) {
                return String(localized: "Translation", table: "Learning")
            }
        }
        for source in LearningReadingSource.allCases where languageLearning.readingEnabled(source) {
            let binding = languageLearning.readingBinding(source)
            if binding.key == keyCode, binding.modifiers == modifiers { return source.title }
        }
        return nil
    }
}
