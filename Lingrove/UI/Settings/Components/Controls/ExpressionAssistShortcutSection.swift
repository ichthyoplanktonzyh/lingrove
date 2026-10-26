import CoreGraphics
import SwiftUI

/// Uses the shared shortcut recorder but observes the nested interaction settings directly, so a
/// recorded binding repaints immediately without forwarding all child changes through translation.
struct ExpressionAssistShortcutSection: View {
    @ObservedObject var settings: ExpressionAssistSettings
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var recording: ShortcutRecordingState

    var body: some View {
        Section(String(localized: "Expression assistance", table: "Learning")) {
            LabeledContent(String(localized: "Open expression assistance", table: "Learning")) {
                KeybindRow(label: settings.keyLabel, keyCode: CGKeyCode(settings.keyCode),
                    isRecording: recording.binding(for: "expressionAssist.open"),
                    onRecord: { key, modifiers, label in
                        settings.keyCode = UInt16(clamping: key)
                        settings.modifiers = modifiers
                        settings.keyLabel = label
                    }, onReset: clear,
                    resetLabel: String(localized: "Reset"), shouldShowReset: true,
                    onClear: clear, clearLabel: String(localized: "Clear"),
                    clearHelp: String(localized: "Disable this shortcut", table: "Learning"),
                    conflictChecker: { code, modifiers in
                        suggestionSettings.expressionAssistShortcutConflict(keyCode: code, modifiers: modifiers)
                    })
            }
            .settingsItem(.expressionAssistShortcut)
            if let conflict = suggestionSettings.expressionAssistShortcutConflict(
                keyCode: CGKeyCode(settings.keyCode), modifiers: settings.modifiers) {
                Text(String(localized: "This shortcut conflicts with \(conflict). Choose a different key combination.", table: "Learning"))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func clear() {
        settings.keyCode = .max
        settings.modifiers = []
        settings.keyLabel = SuggestionSettingsModel.disabledKeyLabel
    }
}
