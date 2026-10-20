import SwiftUI

/// The language-learning Form supplies the shared settings owner. These rows only enable and
/// order local sources; loading dictionaries and cancelling stale queries remain session work.
struct DictionarySettingsSection: View {
    @ObservedObject var settings: LearningDictionarySettings

    var body: some View {
        Section(String(localized: "Dictionary sources", table: "Learning")) {
            ForEach(Array(settings.configuration.order.enumerated()), id: \.element) { index, source in
                HStack(spacing: 12) {
                    Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
                    Toggle(isOn: Binding(get: { settings.configuration.enabled.contains(source) },
                        set: { settings.setEnabled($0, for: source) })) {
                        SettingsRowLabel(title: source.label, description: description(source), systemImage: "books.vertical")
                    }
                    .disabled(settings.configuration.enabled == [source])
                    HStack(spacing: 4) {
                        Button { settings.move(source, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help(String(localized: "Move source up", table: "Learning"))
                            .accessibilityLabel(String(localized: "Move source up", table: "Learning"))
                        Button { settings.move(source, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == settings.configuration.order.count - 1)
                            .help(String(localized: "Move source down", table: "Learning"))
                            .accessibilityLabel(String(localized: "Move source down", table: "Learning"))
                    }.buttonStyle(.borderless)
                }
            }
        }.settingsItem(.dictionarySources)
        Section(String(localized: "Dictionary data", table: "Learning")) {
            LabeledContent(String(localized: "Built-in expressions", table: "Learning"), value: "Wiktionary / Kaikki")
            LabeledContent(String(localized: "License", table: "Learning"), value: "CC BY-SA 4.0")
            LabeledContent(String(localized: "System Dictionary", table: "Learning"),
                           value: String(localized: "Follows macOS Dictionary settings", table: "Learning"))
        }
    }

    private func description(_ source: LearningDictionarySource) -> String {
        switch source {
        case .bundled: String(localized: "Phrases and fixed expressions", table: "Learning")
        case .system: String(localized: "Enabled macOS dictionaries", table: "Learning")
        }
    }
}
