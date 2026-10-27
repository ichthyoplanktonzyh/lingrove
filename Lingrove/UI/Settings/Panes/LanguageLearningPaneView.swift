import SwiftUI

/// A fixed segmented picker mirrors Engine & Model while one native Form shows only the chosen
/// learning area's behavior. The window owns tab state; app-owned settings/controllers retain
/// their existing keys and lifetimes, including while another area's form is not mounted.
struct LanguageLearningPaneView: View {
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let speech: LearningSpeechController?
    var review: AnkiReviewController?
    let configureModel: (LearningModelRole) -> Void
    let openSpeechSettings: () -> Void
    let openShortcuts: () -> Void
    var openApps: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Language Learning", table: "Learning"), selection: Binding(
                get: { navigation.learningTask }, set: navigation.openLearningTask)) {
                ForEach(SettingsLearningTask.allCases) { task in Text(task.label).tag(task) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Language Learning", table: "Learning"))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            SettingsPaneScaffold {
                switch navigation.learningTask {
                case .review:
                    if let review { LearningReviewSettingsSection(controller: review) }
                case .translation:
                    LanguageLearningSection(settings: suggestionSettings.languageLearning, role: .translation,
                        configureModel: configureModel, openShortcuts: openShortcuts, openApps: openApps,
                        openExpressionAssist: { navigation.reveal(.expressionAssist) })
                case .explanation:
                    LanguageLearningSection(settings: suggestionSettings.languageLearning, role: .explanation,
                        configureModel: configureModel, openShortcuts: openShortcuts)
                case .dictionary:
                    DictionarySettingsSection(settings: suggestionSettings.languageLearning.dictionary)
                case .readAloud:
                    if let speech {
                        ReadAloudSettingsSection(speech: speech, openSpeechSettings: openSpeechSettings)
                    } else {
                        Section(String(localized: "Read Aloud", table: "Learning")) {
                            Text(String(localized: "Speech settings are unavailable. Reopen Settings to try again.", table: "Learning"))
                        }
                    }
                }
            }
            // Each area gets its own Form identity so a tall source-language disclosure cannot
            // carry its scroll offset into the short read-aloud page. The picker stays fixed.
            .id(navigation.learningTask)
        }
    }
}

/// One section borrows the shared speech controller for playback speed and a configuration link.
/// It creates no voices or audio services; tab changes only mount or unmount these controls.
private struct ReadAloudSettingsSection: View {
    @ObservedObject var speech: LearningSpeechController
    let openSpeechSettings: () -> Void

    private var rateBinding: Binding<Double> {
        Binding(
            get: { speech.settings.rateMultiplier },
            set: { speech.settings.setRateMultiplier($0) })
    }

    var body: some View {
        Section(String(localized: "Read Aloud", table: "Learning")) {
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: rateBinding,
                        in: LearningSpeechSettings.minimumRateMultiplier...LearningSpeechSettings.maximumRateMultiplier,
                        step: 0.1)
                        .accessibilityLabel(String(localized: "Default speaking speed", table: "Learning"))
                        .accessibilityValue(speedLabel)
                    Text(speedLabel).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .frame(maxWidth: 280)
            } label: {
                SettingsRowLabel(
                    title: String(localized: "Default speaking speed", table: "Learning"),
                    description: String(localized: "Set the default speed for reading learning text aloud.", table: "Learning"),
                    systemImage: "speedometer")
            }
            .settingsItem(.readAloudSpeed)

            LabeledContent {
                Text(providerName).foregroundStyle(.secondary)
            } label: {
                SettingsRowLabel(
                    title: String(localized: "Current provider", table: "Learning"),
                    description: String(localized: "Choose the provider and voices in TTS settings.", table: "Learning"),
                    systemImage: "speaker.wave.2")
            }
            Button(action: openSpeechSettings) {
                Label(String(localized: "Open TTS settings", table: "Learning"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.link)
            .help(String(localized: "Open TTS settings to configure and test speech.", table: "Learning"))
        }
    }

    private var providerName: String {
        speech.settings.selectedProvider.label
    }

    private var speedLabel: String {
        speech.settings.rateMultiplier.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}
