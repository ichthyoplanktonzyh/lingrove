import SwiftUI

/// Setup reads the same durable bindings as the guide. Editors remain in the central Shortcuts
/// pane; this window only selects which product area to introduce and routes each row there.
struct WelcomeKeybindStepView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var learning: LanguageLearningSettings
    @ObservedObject var vocabulary: VocabularyShortcutSettings
    let open: (SettingsItem) -> Void
    @State private var area = ProductFeatureArea.completion

    var body: some View {
        VStack(spacing: 20) {
            OnboardingStepHeader(systemImage: "keyboard", title: String(localized: "Shortcuts"),
                subtitle: String(localized: "View your current keys. Edit them in Shortcuts settings.", table: "Learning"))
            Picker(String(localized: "Shortcuts"), selection: $area) {
                ForEach(ProductFeatureArea.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("welcomeShortcutArea")
            VStack(spacing: 14) {
                if area == .completion {
                    row(.acceptWord, key: suggestionSettings.acceptanceKeyCode, label: suggestionSettings.acceptanceKeyLabel)
                    CurrentShortcutRow(title: SettingsItem.acceptEntireSuggestion.title,
                        isBound: suggestionSettings.hasFullAcceptanceShortcut, label: suggestionSettings.fullAcceptanceDisplayLabel) {
                            open(.acceptEntireSuggestion)
                        }
                    row(.toggleLingrove, key: suggestionSettings.globalToggleKeyCode, label: suggestionSettings.globalToggleKeyLabel)
                } else {
                    ExpressionAssistIntroduction(settings: learning.expressionAssist, allowsEnabling: true, open: open)
                    row(.replacementTranslationShortcut, key: learning.replacementKeyCode, label: learning.replacementKeyLabel)
                    row(.translationDetailsShortcut, key: learning.keyCode, label: learning.keyLabel)
                    ForEach(LearningReadingSource.allCases, id: \.rawValue) { source in
                        let binding = learning.readingBinding(source)
                        row(source == .selection ? .selectionTranslationShortcut
                            : source == .pointer ? .pointerTranslationShortcut : .screenshotTranslationShortcut,
                            key: binding.key, label: binding.label)
                    }
                    ForEach(VocabularyShortcutSettings.Command.allCases, id: \.rawValue) { command in
                        let binding = vocabulary.binding(command)
                        row(command == .save ? .saveVocabularyShortcut : .openVocabularyShortcut,
                            key: binding.key, label: binding.label)
                    }
                }
            }.padding(18).onboardingCard()
        }
    }
    private func row(_ item: SettingsItem, key: UInt16, label: String) -> some View {
        CurrentShortcutRow(title: item.title, isBound: key != .max, label: label) { open(item) }
    }
}
