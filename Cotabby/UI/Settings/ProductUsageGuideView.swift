import SwiftUI

/// A read-only sheet owned by SettingsContainerView, separate from first-run setup. It observes
/// existing settings only to describe the user's current shortcuts. Destination actions close the
/// sheet through the owner and reuse SettingsNavigationModel's exact-row routing.
struct ProductUsageGuideView: View {
    @ObservedObject var settings: SuggestionSettingsModel
    let open: (SettingsItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var area = ProductFeatureArea.completion

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(String(localized: "Usage Guide", table: "Learning")).font(.title2.weight(.semibold))
                Spacer()
                Button(String(localized: "Close", table: "Learning")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker(String(localized: "Quick controls", table: "Learning"), selection: $area) {
                ForEach(ProductFeatureArea.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("usageGuideArea")
            ScrollView {
                VStack(spacing: 16) {
                    switch area {
                    case .completion:
                        OnboardingFeatureShowcase(autoplay: false, showsMacroReference: true)
                        UsageGuideSection(title: String(localized: "Autocomplete"),
                            description: String(localized: "Insert the next word or the entire suggestion with your configured shortcuts.",
                                table: "Learning"), systemImage: "text.cursor") {
                            UsageGuideShortcutRow(title: String(localized: "Accept Word"),
                                isBound: settings.acceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode,
                                label: settings.acceptanceKeyLabel) { open(.acceptWord) }
                            UsageGuideShortcutRow(title: String(localized: "Accept Entire Suggestion"),
                                isBound: settings.hasFullAcceptanceShortcut,
                                label: settings.fullAcceptanceDisplayLabel) { open(.acceptEntireSuggestion) }
                            Button(String(localized: "Writing")) { open(.completionEnabled) }
                                .buttonStyle(.borderless)
                        }
                    case .learning:
                        LearningFeatureShowcase()
                        LearningUsageGuideTopics(settings: settings.languageLearning,
                            vocabularyShortcuts: settings.vocabularyShortcuts, open: open)
                    }
                }.padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .accessibilityIdentifier("productUsageGuide")
    }
}

/// Nested stores are observed locally so rebinding a shortcut updates its help row without
/// constructing a runtime or making the whole settings container observe learning publications.
private struct LearningUsageGuideTopics: View {
    @ObservedObject var settings: LanguageLearningSettings
    @ObservedObject var vocabularyShortcuts: VocabularyShortcutSettings
    let open: (SettingsItem) -> Void

    var body: some View {
        VStack(spacing: 12) {
            UsageGuideSection(title: String(localized: "Writing translation", table: "Learning"),
                description: String(
                    localized: "Pause to preview the current sentence. Use ⇄ to replace its source; a selection takes priority.",
                    table: "Learning"), systemImage: "character.bubble") {
                UsageGuideShortcutRow(title: String(localized: "Replace preview translation", table: "Learning"),
                    isBound: settings.replacementKeyCode != .max,
                    label: settings.replacementKeyLabel) { open(.replacementTranslationShortcut) }
                UsageGuideShortcutRow(title: String(localized: "Expand / collapse translation details", table: "Learning"),
                    isBound: settings.keyCode != .max,
                    label: settings.keyLabel) { open(.translationDetailsShortcut) }
                settingsButton(.sentencePreview)
            }
            UsageGuideSection(title: String(localized: "Reading translation", table: "Learning"),
                description: String(localized: "Select text, point at text with the configured shortcut, or capture a screen region.",
                    table: "Learning"), systemImage: "text.viewfinder") {
                ForEach(LearningReadingSource.allCases, id: \.rawValue) { source in
                    let binding = settings.readingBinding(source)
                    UsageGuideShortcutRow(title: source.title, isBound: binding.key != .max, label: binding.label) {
                        open(source == .selection ? .selectionTranslationShortcut
                            : source == .pointer ? .pointerTranslationShortcut : .screenshotTranslationShortcut)
                    }
                }
                settingsButton(.selectionTranslation)
            }
            UsageGuideSection(title: String(localized: "AI explanation", table: "Learning"),
                description: String(localized: "Query a word or expression for its meaning in context. Expand to read the explanation.",
                    table: "Learning"), systemImage: "sparkles") { settingsButton(.explanationLanguage) }
            UsageGuideSection(title: String(localized: "Dictionary", table: "Learning"),
                description: String(localized: "Switch dictionary sources in the lookup card.", table: "Learning"),
                systemImage: "book.closed") { settingsButton(.dictionarySources) }
            UsageGuideSection(title: String(localized: "Read Aloud", table: "Learning"),
                description: String(localized: "Click the speaker beside a word, expression, or sentence. The language follows the text.",
                    table: "Learning"), systemImage: "speaker.wave.2") { settingsButton(.readAloudSpeed) }
            UsageGuideSection(title: String(localized: "Vocabulary", table: "Vocabulary"),
                description: String(localized: "Click the fish tail to save a sense with its example. Find it again in Vocabulary.",
                    table: "Learning"), systemImage: nil) {
                ForEach(VocabularyShortcutSettings.Command.allCases, id: \.rawValue) { command in
                    let binding = vocabularyShortcuts.binding(command)
                    UsageGuideShortcutRow(title: command.title, isBound: binding.key != .max, label: binding.label) {
                        open(command == .save ? .saveVocabularyShortcut : .openVocabularyShortcut)
                    }
                }
            }
            UsageGuideSection(title: String(localized: "Review", table: "Vocabulary"),
                description: String(localized: "Send saved senses to Anki, choose card faces, and review them.", table: "Learning"),
                systemImage: "rectangle.stack") { settingsButton(.ankiReview) }
        }
    }

    private func settingsButton(_ item: SettingsItem) -> some View {
        Button(String(localized: "Settings")) { open(item) }.buttonStyle(.borderless)
    }
}

/// Uses the existing native settings label inside a lightweight group. It describes one action
/// and exposes only navigation; no feature toggles, downloads or real card controls are mounted.
private struct UsageGuideSection<Content: View>: View {
    let title: String
    let description: String
    let systemImage: String?
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRowLabel(title: title, description: description, systemImage: systemImage)
                content
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}

/// An unbound action offers the existing Shortcuts pane instead of inventing a default key.
/// Bound labels come directly from the app's current settings, including double-tap acceptance.
private struct UsageGuideShortcutRow: View {
    let title: String
    let isBound: Bool
    let label: String
    let open: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer(minLength: 12)
            Button(action: open) {
                Text(isBound ? label : String(localized: "Shortcuts"))
                    .font(.subheadline.monospaced())
            }.buttonStyle(.borderless).help(String(localized: "Shortcuts"))
        }
    }
}
