import CoreGraphics
import SwiftUI

/// Reuses the existing recorder; no shortcut editor is duplicated in cards or the library.
struct VocabularyShortcutRows: View {
    @ObservedObject var settings: VocabularyShortcutSettings
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var recording: ShortcutRecordingState

    var body: some View {
        Section(String(localized: "Vocabulary", table: "Vocabulary")) {
            ForEach(VocabularyShortcutSettings.Command.allCases, id: \.rawValue) { command in
                let binding = settings.binding(command)
                LabeledContent(command.title) {
                    KeybindRow(label: binding.key == .max ? SuggestionSettingsModel.disabledKeyLabel : binding.label,
                        keyCode: CGKeyCode(binding.key), isRecording: recording.binding(for: "vocabulary." + command.rawValue),
                        onRecord: { key, modifiers, label in
                            settings.set(command, key: UInt16(clamping: key), modifiers: modifiers, label: label)
                        }, onReset: nil, resetLabel: String(localized: "Reset"), shouldShowReset: false,
                        onClear: { settings.set(command, key: .max, modifiers: [], label: "") },
                        clearLabel: String(localized: "Clear"),
                        clearHelp: String(localized: "Disable this shortcut", table: "Learning"),
                        conflictChecker: { key, modifiers in
                            suggestionSettings.vocabularyShortcutConflict(command, key: UInt16(clamping: key), modifiers: modifiers)
                        })
                }
                .settingsItem(command == .save ? .saveVocabularyShortcut : .openVocabularyShortcut)
                if let reason = suggestionSettings.vocabularyShortcutConflict(command, key: binding.key, modifiers: binding.modifiers) {
                    Text(String(localized: "This shortcut conflicts with \(reason). Choose a different key combination.",
                        table: "Learning"))
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}

extension SuggestionSettingsModel {
    /// Check every effective app binding in the recorder, but only the current host at dispatch.
    func vocabularyShortcutConflict(_ command: VocabularyShortcutSettings.Command, key: UInt16,
                                    modifiers: ShortcutModifierMask, bundle: String? = nil) -> String? {
        guard key != .max else { return nil }
        guard !modifiers.isEmpty, ![36, 76, 53].contains(key) else {
            return String(localized: "Use a shortcut with a modifier key; Enter and Escape are reserved.", table: "Learning")
        }
        if let other = vocabularyShortcuts.command(key: key, modifiers: modifiers, excluding: command) { return other.title }
        // Exclude notebook bindings to avoid finding this command itself; the regular policy
        // still checks completion, global toggle, writing translation and all reading shortcuts.
        for app in bundle.map({ [$0] }) ?? ([""] + perAppShortcutOverrides.map(\.bundleIdentifier)) {
            if let reason = conflictingPerAppShortcutName(forBundleIdentifier: app, keyCode: CGKeyCode(key), modifiers: modifiers,
                excluding: .toggleLingrove, includingVocabularyShortcut: false) { return reason }
        }
        return nil
    }
}
