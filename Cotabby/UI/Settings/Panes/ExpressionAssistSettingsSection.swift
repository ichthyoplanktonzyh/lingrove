import SwiftUI

/// Interaction settings observe their own persisted model. Translation may be off while the user
/// explicitly asks for an expression; only the target language and shared general model are reused.
struct ExpressionAssistSettingsSection: View {
    @ObservedObject var settings: ExpressionAssistSettings
    @ObservedObject var learning: LanguageLearningSettings
    let openShortcuts: () -> Void

    var body: some View {
        Section(String(localized: "Expression assistance", table: "Learning")) {
            Toggle(isOn: $settings.enabled) {
                SettingsRowLabel(title: String(localized: "Find an expression or term while writing", table: "Learning"),
                    description: String(localized: "Describe what you mean at the caret. Confirm a candidate to insert it.",
                        table: "Learning"),
                    systemImage: "text.magnifyingglass")
            }
            .accessibilityLabel(String(localized: "Find an expression or term while writing", table: "Learning"))
            .settingsItem(.expressionAssist)
            LabeledContent(String(localized: "Trigger symbols", table: "Learning")) {
                TextField("", text: $settings.trigger, prompt: Text(verbatim: "??"))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                    .accessibilityLabel(String(localized: "Trigger symbols", table: "Learning"))
            }
            if let error = ExpressionAssistPolicy.triggerError(settings.trigger) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Picker(String(localized: "Target language", table: "Learning"), selection: $learning.targetLanguage) {
                ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
            }
            Button(String(localized: "Configure an expression shortcut", table: "Learning"), action: openShortcuts)
            Text(String(localized: """
            Uses the AI explanation model below. With a configured endpoint, your description, selected text and bounded neighboring \
            text are sent to that service. Temporary descriptions stay out of the original editor.
            """, table: "Learning"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
