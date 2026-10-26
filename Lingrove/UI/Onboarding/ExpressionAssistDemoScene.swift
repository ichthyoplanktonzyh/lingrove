import SwiftUI

/// One bounded scene in the existing player. The sentence and candidates are reviewed sample
/// content; only the current trigger comes from settings. Its local insertion never touches AX,
/// the global keyboard, model services, or the user's document.
struct ExpressionAssistDemoScene: View {
    let action: HomeLearningDemoAction
    @ObservedObject var settings: ExpressionAssistSettings
    let insert: () -> Void
    @State private var selected = 0
    private let candidates = [
        ExpressionAssistCandidate(text: "keep me posted", hint: "让我随时了解最新情况", dictionaryForm: "keep someone posted"),
        ExpressionAssistCandidate(text: "keep me updated", hint: "持续向我提供最新消息", dictionaryForm: nil)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: action == .expressionInsert
                ? "Please \(candidates[selected].text) on the project's progress."
                : "Please \(settings.trigger) on the project's progress.")
                .font(.body).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if action == .expressionDescribe || action == .expressionChoose {
                Label(String(localized: "Describe what you mean", table: "Learning"), systemImage: "text.cursor")
                    .font(.caption).foregroundStyle(.secondary)
                // This Chinese query and English answer are language-learning material, not UI copy.
                Text(verbatim: "让我随时了解最新进展").padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
            if action == .expressionChoose {
                ForEach(candidates.indices, id: \.self) { index in
                    SampleExpressionCandidate(candidate: candidates[index], selected: selected == index) {
                        selected = index
                        insert()
                    }.frame(height: index == 0 ? 72 : 56)
                }
                Text(verbatim: "↑↓   ·   ↵ / Tab   ·   Esc").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(8).accessibilityIdentifier("expressionAssistDemo")
            .onChange(of: action) { _, action in if action == .expressionTrigger { selected = 0 } }
    }
}

/// The example uses the production candidate row so its typography and selection treatment stay
/// accurate. This small adapter owns only a button target; the player owns the example's step.
private struct SampleExpressionCandidate: NSViewRepresentable {
    let candidate: ExpressionAssistCandidate
    let selected: Bool
    let insert: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(insert: insert) }
    func makeNSView(context: Context) -> ExpressionAssistCandidateRow {
        let row = ExpressionAssistCandidateRow(candidate: candidate, selected: selected, expanded: true)
        row.target = context.coordinator
        row.action = #selector(Coordinator.accept)
        return row
    }
    func updateNSView(_ row: ExpressionAssistCandidateRow, context: Context) { context.coordinator.insert = insert }
    final class Coordinator: NSObject {
        var insert: () -> Void
        init(insert: @escaping () -> Void) { self.insert = insert }
        @objc func accept() { insert() }
    }
}

/// A live, brief entry point shared by the guide and setup. It observes the nested preferences so
/// enabling the feature or rebinding a shortcut elsewhere immediately updates the introduction.
struct ExpressionAssistIntroduction: View {
    @ObservedObject var settings: ExpressionAssistSettings
    var allowsEnabling = false
    let open: (SettingsItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allowsEnabling {
                Toggle(String(localized: "Expression assistance", table: "Learning"), isOn: $settings.enabled)
            } else {
                Button(String(localized: "Expression assistance", table: "Learning")) { open(.expressionAssist) }
            }
            LabeledContent(String(localized: "Trigger symbols", table: "Learning")) {
                Button(settings.trigger) { open(.expressionAssist) }.buttonStyle(.link)
            }
            CurrentShortcutRow(title: SettingsItem.expressionAssistShortcut.title,
                isBound: settings.keyCode != .max, label: settings.keyLabel) { open(.expressionAssistShortcut) }
        }
    }
}
