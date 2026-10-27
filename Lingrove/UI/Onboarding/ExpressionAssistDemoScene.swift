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
        VStack(alignment: .leading, spacing: 8) {
            editorLine
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if action == .expressionDescribe {
                Label(String(localized: "Describe what you mean", table: "Learning"), systemImage: "text.cursor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            if action == .expressionChoose {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(candidates.indices, id: \.self) { index in
                        SampleExpressionCandidate(
                            candidate: candidates[index],
                            index: index,
                            selected: selected == index
                        ) {
                            selected = index
                            insert()
                        }
                        .frame(height: index == 0 ? 64 : 46)
                    }
                    Divider().opacity(0.5).padding(.vertical, 2)
                    Text(verbatim: "↑↓ Select   ·   ↵ / Tab Insert   ·   Esc Cancel")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                }
                .padding(8)
                .frame(maxWidth: 380, alignment: .leading)
                .learningCardChrome(cornerRadius: 10)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.leading, 36)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .accessibilityIdentifier("expressionAssistDemo")
        .onChange(of: action) { _, action in if action == .expressionTrigger { selected = 0 } }
    }

    /// Renders the host sentence with an inline preedit description right after the trigger,
    /// mirroring the real ghost-text-aligned `NSTextView` in `ExpressionAssistPanelController`.
    @ViewBuilder
    private var editorLine: some View {
        switch action {
        case .expressionInsert:
            (Text(verbatim: "Please ")
                + Text(verbatim: candidates[selected].text).foregroundStyle(Color.accentColor).fontWeight(.medium)
                + Text(verbatim: " on the project's progress."))
                .font(.body)
        case .expressionDescribe, .expressionChoose:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "Please \(settings.trigger)")
                    .font(.body)
                // This Chinese query and English answer are language-learning material, not UI copy.
                Text(verbatim: "让我随时了解最新进展")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.82))
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottomLeading) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.45))
                            .frame(height: 1.5)
                    }
                Text(verbatim: " on the project's progress.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        default:
            Text(verbatim: "Please \(settings.trigger) on the project's progress.")
                .font(.body)
        }
    }
}

/// The example uses the production candidate row so its typography and selection treatment stay
/// accurate. This small adapter owns only a button target; the player owns the example's step.
private struct SampleExpressionCandidate: NSViewRepresentable {
    let candidate: ExpressionAssistCandidate
    let index: Int
    let selected: Bool
    let insert: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(insert: insert) }
    func makeNSView(context: Context) -> ExpressionAssistCandidateRow {
        let row = ExpressionAssistCandidateRow(
            candidate: candidate,
            index: index,
            selected: selected,
            expanded: true,
            onSpeak: {},
            onToggleFavorite: {}
        )
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
