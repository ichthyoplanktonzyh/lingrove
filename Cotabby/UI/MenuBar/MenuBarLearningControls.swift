import SwiftUI

/// Mounted only on the learning page. It borrows the app's durable learning settings, while
/// disclosure expansion remains local UI state. Direct native Toggles, eight-point stack spacing
/// and the original MenuBarPickerRow follow the restored completion panel. No custom switch row
/// stretches labels or repositions controls; model configuration remains in Settings.
struct MenuBarLearningControls: View {
    @ObservedObject var settings: LanguageLearningSettings
    let speech: LearningSpeechController
    let screenRecordingGranted: Bool
    let open: (MenuBarSettingsDestination) -> Void
    let review: () -> Void
    @State private var explanationExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(String(localized: "Translation", table: "Learning"), isOn: $settings.translationEnabled)
                .controlSize(.small).accessibilityIdentifier("menuTranslationEnabled")

            Divider()
            heading(String(localized: "Writing"))
            Toggle(String(localized: "Automatic translation preview", table: "Learning"),
                isOn: $settings.sentencePreviewEnabled)
                .controlSize(.small).disabled(!settings.translationEnabled)
                .accessibilityIdentifier("menuSentencePreview")
            languageRow(selection: $settings.targetLanguage, identifier: "menuWritingTarget")

            Divider()
            heading(String(localized: "Reading", table: "Learning"))
            Toggle(String(localized: "Enable selection translation", table: "Learning"),
                isOn: $settings.selectionTranslationEnabled)
                .controlSize(.small).disabled(!settings.translationEnabled).accessibilityIdentifier("menuSelectionTranslation")
            Toggle(String(localized: "Enable pointer translation", table: "Learning"),
                isOn: $settings.pointerTranslationEnabled)
                .controlSize(.small).disabled(!settings.translationEnabled).accessibilityIdentifier("menuPointerTranslation")
            Toggle(String(localized: "Enable screen region translation", table: "Learning"),
                isOn: $settings.screenshotTranslationEnabled)
                .controlSize(.small).disabled(!settings.translationEnabled).accessibilityIdentifier("menuRegionTranslation")
            if settings.translationEnabled && settings.screenshotTranslationEnabled && !screenRecordingGranted {
                Button { open(.category(.permissions)) } label: {
                    Text(String(localized: "Unavailable while Screen Recording is off"))
                        .font(.caption2).foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
            languageRow(selection: $settings.readingTargetLanguage, identifier: "menuReadingTarget")

            Divider()
            MenuBarLearningModelRow(profile: settings.translation) { open(.model(.translation)) }
            DisclosureGroup(isExpanded: $explanationExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    MenuBarPickerRow(title: String(localized: "Explanation language", table: "Learning")) {
                        Picker(String(localized: "Explanation language", table: "Learning"), selection: $settings.explanationLanguage) {
                            Text(String(localized: "Interface language", table: "Learning")).tag(nil as LearningLanguage?)
                            ForEach(LearningLanguage.allCases) { Text($0.label).tag(Optional($0)) }
                        }.labelsHidden().pickerStyle(.menu).accessibilityIdentifier("menuExplanationLanguage")
                    }
                    MenuBarLearningModelRow(profile: settings.explanation) { open(.model(.explanation)) }
                }.padding(.top, 6)
            } label: {
                HStack {
                    Text(String(localized: "AI explanation", table: "Learning"))
                    Spacer()
                    Text(settings.explanationLanguage?.label ?? String(localized: "Interface language", table: "Learning"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("menuExplanationDisclosure")

            MenuBarSpeechControls(speech: speech) { open(.model(.speech)) }
            Button { open(.learning(.dictionary)) } label: {
                Label(String(localized: "Dictionary", table: "Learning"), systemImage: "book.closed")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless)
            Button(action: review) {
                Label(String(localized: "Review", table: "Vocabulary"), systemImage: "rectangle.stack.badge.play")
            }.buttonStyle(.borderless)
            Button { open(.learning(.translation)) } label: {
                Label(String(localized: "Language Learning", table: "Learning") + "…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless)
        }
        .toggleStyle(.switch)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
    }

    private func languageRow(selection: Binding<LearningLanguage>, identifier: String) -> some View {
        MenuBarPickerRow(title: String(localized: "Target language", table: "Learning")) {
            Picker(String(localized: "Target language", table: "Learning"), selection: selection) {
                ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.menu).disabled(!settings.translationEnabled)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// Observes the nested role directly, so a model changed in Settings updates this summary too.
/// Reading its snapshot is pure: opening the menu never discovers endpoints, scans directories,
/// loads weights or enumerates speech voices. Configuration stays in Engine & Model.
private struct MenuBarLearningModelRow: View {
    @ObservedObject var profile: LearningModelSettings
    let configure: () -> Void

    var body: some View {
        let snapshot = profile.snapshot
        let name = snapshot.backend == .local ? snapshot.localModel : snapshot.endpointModel
        let configured = snapshot.backend == .local ? !name.isEmpty :
            (try? OpenAICompatibleEndpointConfiguration(baseURLString: snapshot.baseURL,
                modelName: snapshot.endpointModel, apiMode: .chatCompletions)) != nil
        MenuBarPickerRow(title: String(localized: "Model")) {
            Button(action: configure) {
                HStack(spacing: 5) {
                    Text(configured ? name : String(localized: "Configure model", table: "Learning"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.borderless).foregroundStyle(configured ? Color.secondary : Color.orange)
                .help(configured ? name : String(localized: "Configure model", table: "Learning"))
        }
    }
}

/// The app-owned speaker forwards its settings changes and playback phase. This view owns
/// neither an audio engine nor a catalog; the global stop action also works with it collapsed.
private struct MenuBarSpeechControls: View {
    @ObservedObject var speech: LearningSpeechController
    let configure: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    MenuBarPickerRow(title: String(localized: "Speed", table: "Learning")) {
                        HStack(spacing: 8) {
                            Slider(value: Binding(get: { speech.settings.rateMultiplier },
                                set: { speech.settings.setRateMultiplier($0) }),
                                in: LearningSpeechSettings.minimumRateMultiplier...LearningSpeechSettings.maximumRateMultiplier,
                                step: 0.1)
                                .accessibilityLabel(String(localized: "Default speaking speed", table: "Learning"))
                                .accessibilityIdentifier("menuSpeechRate")
                            Text(rateLabel).monospacedDigit().font(.caption).frame(width: 34, alignment: .trailing)
                        }
                    }
                    Text(speech.settings.selectedProvider.label).font(.caption).foregroundStyle(.secondary)
                    Button(String(localized: "Open TTS settings", table: "Learning"), action: configure)
                        .buttonStyle(.borderless)
                }.padding(.top, 6)
            } label: {
                HStack {
                    Text(String(localized: "Read Aloud", table: "Learning"))
                    Spacer()
                    Text(rateLabel).font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("menuSpeechDisclosure")
            if speech.phase != nil {
                Button { speech.stop() } label: {
                    Label(String(localized: "Stop reading", table: "Vocabulary"), systemImage: "stop.fill")
                }.buttonStyle(.borderless).accessibilityIdentifier("menuStopSpeech")
            }
        }
    }

    private var rateLabel: String { speech.settings.rateMultiplier.formatted(.number.precision(.fractionLength(1))) + "×" }
}
