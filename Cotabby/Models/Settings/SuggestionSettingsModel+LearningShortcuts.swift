import CoreGraphics
import Foundation

/// One conflict policy serves the learning commands and the existing event-tap arbiter. A settings
/// recorder checks every configured app; dispatch checks only the currently focused app's bindings.
extension SuggestionSettingsModel {
    func learningShortcutConflict(
        keyCode: CGKeyCode, modifiers: ShortcutModifierMask, replacement: Bool,
        bundleIdentifier: String? = nil
    ) -> String? {
        guard keyCode != Self.disabledKeyCode else { return nil }
        if [36, 76, 53].contains(keyCode) || modifiers.isEmpty {
            return String(localized: "Use a shortcut with a modifier key; Enter and Escape are reserved.", table: "Learning")
        }
        let otherCode = replacement ? languageLearning.keyCode : languageLearning.replacementKeyCode
        let otherModifiers = replacement ? languageLearning.modifiers : languageLearning.replacementModifiers
        if keyCode == otherCode, modifiers == otherModifiers {
            return String(localized: "Translation shortcut", table: "Learning", comment: "Conflicting translation action name.")
        }
        for source in LearningReadingSource.allCases where languageLearning.readingEnabled(source) {
            let binding = languageLearning.readingBinding(source)
            if keyCode == binding.key, modifiers == binding.modifiers,
                (bundleIdentifier.map { [$0] } ?? perAppShortcutOverrides.map(\.bundleIdentifier)).contains(where: {
                    readingTranslationAllowed(source, in: $0) && writingTranslationShortcutsAllowed(in: $0)
                })
            {
                return source.title
            }
        }
        let apps = bundleIdentifier.map { [$0] } ?? ([""] + perAppShortcutOverrides.map(\.bundleIdentifier))
        for app in apps {
            if let conflict = conflictingPerAppShortcutName(
                forBundleIdentifier: app, keyCode: keyCode, modifiers: modifiers,
                excluding: .toggleTabby, includingLearningShortcut: false)
            {
                return conflict
            }
        }
        return nil
    }

    func selectionShortcutConflict(
        bundleIdentifier: String? = nil, keyCode: CGKeyCode? = nil,
        modifiers: ShortcutModifierMask? = nil
    ) -> String? {
        readingShortcutConflict(.selection, bundleIdentifier: bundleIdentifier, keyCode: keyCode, modifiers: modifiers)
    }

    func readingShortcutConflict(
        _ source: LearningReadingSource, bundleIdentifier: String? = nil,
        keyCode: CGKeyCode? = nil, modifiers: ShortcutModifierMask? = nil
    ) -> String? {
        let binding = languageLearning.readingBinding(source)
        let key = keyCode ?? binding.key
        let mask = modifiers ?? binding.modifiers
        guard key != Self.disabledKeyCode else { return nil }
        guard !mask.isEmpty, ![36, 76, 53].contains(key) else {
            return String(localized: "Use a shortcut with a modifier key; Enter and Escape are reserved.", table: "Learning")
        }
        let apps =
            bundleIdentifier.map { [$0] }
            ?? perAppShortcutOverrides.filter {
                readingTranslationAllowed(source, in: $0.bundleIdentifier)
            }.map(\.bundleIdentifier)
        if apps.contains(where: { writingTranslationShortcutsAllowed(in: $0) }),
            (key == languageLearning.keyCode && mask == languageLearning.modifiers)
                || (key == languageLearning.replacementKeyCode && mask == languageLearning.replacementModifiers)
        {
            return String(localized: "Translation shortcut", table: "Learning")
        }
        for other in LearningReadingSource.allCases where other != source && languageLearning.readingEnabled(other) {
            let otherBinding = languageLearning.readingBinding(other)
            if key == otherBinding.key, mask == otherBinding.modifiers { return other.title }
        }
        // An empty allowlist still checks global bindings, so a newly allowed app cannot silently
        // inherit a conflict that the recorder previously accepted without any app records.
        for app in apps.isEmpty ? [""] : apps {
            if let reason = conflictingPerAppShortcutName(
                forBundleIdentifier: app, keyCode: key, modifiers: mask,
                excluding: .toggleTabby, includingLearningShortcut: false)
            {
                return reason
            }
        }
        return nil
    }

}
