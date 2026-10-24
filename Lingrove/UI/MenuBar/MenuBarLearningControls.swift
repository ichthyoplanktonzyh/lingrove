import SwiftUI

/// File overview:
/// Mounted only on the learning page of the menu-bar popover. It borrows the app's durable
/// `LanguageLearningSettings` and `LearningSpeechController`, while disclosure expansion remains
/// local UI state.
///
/// Architectural boundary:
/// Controls are grouped into calm surface cards (`MenuBarSurfaceCard`) with right-aligned switches
/// (`MenuBarToggleRow`) and interactive destination rows (`MenuBarActionRow`). Model discovery and
/// voice catalog enumeration stay strictly lazy so opening the menu never triggers background I/O.
struct MenuBarLearningControls: View {
    @ObservedObject var settings: LanguageLearningSettings
    let speech: LearningSpeechController
    let screenRecordingGranted: Bool
    let open: (MenuBarSettingsDestination) -> Void
    let review: () -> Void
    @State private var explanationExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card 1: Master translation switch + Writing & Reading triggers
            MenuBarSurfaceCard(padding: 10, spacing: 8) {
                MenuBarToggleRow(
                    title: String(localized: "Translation", table: "Learning"),
                    systemImage: "character.bubble",
                    isOn: $settings.translationEnabled,
                    identifier: "menuTranslationEnabled"
                )

                MenuBarCardDivider()

                VStack(alignment: .leading, spacing: 7) {
                    heading(String(localized: "Writing"), systemImage: "pencil.line")

                    MenuBarToggleRow(
                        title: String(localized: "Automatic translation preview", table: "Learning"),
                        isOn: $settings.sentencePreviewEnabled,
                        isDisabled: !settings.translationEnabled,
                        identifier: "menuSentencePreview"
                    )

                    languageRow(selection: $settings.targetLanguage, identifier: "menuWritingTarget")
                }
                .opacity(settings.translationEnabled ? 1.0 : 0.55)

                MenuBarCardDivider()

                VStack(alignment: .leading, spacing: 7) {
                    heading(String(localized: "Reading", table: "Learning"), systemImage: "text.magnifyingglass")

                    MenuBarToggleRow(
                        title: String(localized: "Enable selection translation", table: "Learning"),
                        isOn: $settings.selectionTranslationEnabled,
                        isDisabled: !settings.translationEnabled,
                        identifier: "menuSelectionTranslation"
                    )

                    MenuBarToggleRow(
                        title: String(localized: "Enable pointer translation", table: "Learning"),
                        isOn: $settings.pointerTranslationEnabled,
                        isDisabled: !settings.translationEnabled,
                        identifier: "menuPointerTranslation"
                    )

                    MenuBarToggleRow(
                        title: String(localized: "Enable screen region translation", table: "Learning"),
                        isOn: $settings.screenshotTranslationEnabled,
                        isDisabled: !settings.translationEnabled,
                        identifier: "menuRegionTranslation"
                    )

                    if settings.translationEnabled && settings.screenshotTranslationEnabled && !screenRecordingGranted {
                        Button {
                            open(.category(.permissions))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(String(localized: "Unavailable while Screen Recording is off"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 6, verticalPadding: 3, cornerRadius: 5))
                    }

                    languageRow(selection: $settings.readingTargetLanguage, identifier: "menuReadingTarget")
                }
                .opacity(settings.translationEnabled ? 1.0 : 0.55)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: settings.translationEnabled)

            // Card 2: Model summary, AI explanation disclosure, and Read Aloud disclosure
            MenuBarSurfaceCard(padding: 10, spacing: 8) {
                MenuBarLearningModelRow(profile: settings.translation) {
                    open(.model(.translation))
                }

                MenuBarCardDivider()

                DisclosureGroup(
                    isExpanded: Binding(
                        get: { explanationExpanded },
                        set: { newValue in
                            if reduceMotion {
                                explanationExpanded = newValue
                            } else {
                                withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                                    explanationExpanded = newValue
                                }
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        MenuBarPickerRow(title: String(localized: "Explanation language", table: "Learning")) {
                            Picker(
                                String(localized: "Explanation language", table: "Learning"),
                                selection: $settings.explanationLanguage
                            ) {
                                Text(String(localized: "Interface language", table: "Learning"))
                                    .tag(nil as LearningLanguage?)
                                ForEach(LearningLanguage.allCases) {
                                    Text($0.label).tag(Optional($0))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("menuExplanationLanguage")
                        }
                        MenuBarLearningModelRow(profile: settings.explanation) {
                            open(.model(.explanation))
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .center)
                            .accessibilityHidden(true)
                        Text(String(localized: "AI explanation", table: "Learning"))
                            .font(.subheadline)
                        Spacer()
                        Text(
                            settings.explanationLanguage?.label
                                ?? String(localized: "Interface language", table: "Learning")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
                .accessibilityIdentifier("menuExplanationDisclosure")

                MenuBarCardDivider()

                MenuBarSpeechControls(speech: speech, reduceMotion: reduceMotion) {
                    open(.model(.speech))
                }
            }

            // Card 3: Quick destinations for Dictionary, Review, and full Learning Settings
            MenuBarSurfaceCard(padding: 4, spacing: 2) {
                MenuBarActionRow(
                    title: String(localized: "Dictionary", table: "Learning"),
                    systemImage: "book.closed",
                    iconTint: .blue
                ) {
                    open(.learning(.dictionary))
                }

                MenuBarActionRow(
                    title: String(localized: "Review", table: "Vocabulary"),
                    systemImage: "rectangle.stack.badge.play",
                    iconTint: .indigo
                ) {
                    review()
                }

                MenuBarActionRow(
                    title: String(localized: "Language Learning", table: "Learning") + "…",
                    systemImage: "slider.horizontal.3",
                    iconTint: .secondary
                ) {
                    open(.learning(.translation))
                }
            }
        }
        .toggleStyle(.switch)
    }

    private func heading(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func languageRow(selection: Binding<LearningLanguage>, identifier: String) -> some View {
        MenuBarPickerRow(title: String(localized: "Target language", table: "Learning")) {
            Picker(String(localized: "Target language", table: "Learning"), selection: selection) {
                ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!settings.translationEnabled)
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
            (try? OpenAICompatibleEndpointConfiguration(
                baseURLString: snapshot.baseURL,
                modelName: snapshot.endpointModel,
                apiMode: .chatCompletions
            )) != nil

        MenuBarPickerRow(title: String(localized: "Model")) {
            Button(action: configure) {
                HStack(spacing: 5) {
                    if !configured {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(configured ? name : String(localized: "Configure model", table: "Learning"))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.75)
                }
                .foregroundStyle(configured ? Color.primary : Color.orange)
            }
            .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 7, verticalPadding: 3, cornerRadius: 6))
            .help(configured ? name : String(localized: "Configure model", table: "Learning"))
        }
    }
}

/// The app-owned speaker forwards its settings changes and playback phase. This view owns
/// neither an audio engine nor a catalog; the global stop action also works with it collapsed.
private struct MenuBarSpeechControls: View {
    @ObservedObject var speech: LearningSpeechController
    let reduceMotion: Bool
    let configure: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded },
                    set: { newValue in
                        if reduceMotion {
                            expanded = newValue
                        } else {
                            withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                                expanded = newValue
                            }
                        }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    MenuBarPickerRow(title: String(localized: "Speed", table: "Learning")) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { speech.settings.rateMultiplier },
                                    set: { speech.settings.setRateMultiplier($0) }
                                ),
                                in: LearningSpeechSettings.minimumRateMultiplier...LearningSpeechSettings.maximumRateMultiplier,
                                step: 0.1
                            )
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "Default speaking speed", table: "Learning"))
                            .accessibilityIdentifier("menuSpeechRate")

                            Text(rateLabel)
                                .monospacedDigit()
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text(speech.settings.selectedProvider.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(action: configure) {
                            HStack(spacing: 3) {
                                Text(String(localized: "Open TTS settings", table: "Learning"))
                                    .font(.caption.weight(.medium))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 6, verticalPadding: 2, cornerRadius: 5))
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)
                        .accessibilityHidden(true)
                    Text(String(localized: "Read Aloud", table: "Learning"))
                        .font(.subheadline)
                    Spacer()
                    Text(rateLabel)
                        .monospacedDigit()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            .accessibilityIdentifier("menuSpeechDisclosure")

            if speech.phase != nil {
                Button {
                    speech.stop()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                        Text(String(localized: "Stop reading", table: "Vocabulary"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 8, verticalPadding: 4, cornerRadius: 6))
                .accessibilityIdentifier("menuStopSpeech")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0), value: speech.phase != nil)
    }

    private var rateLabel: String {
        speech.settings.rateMultiplier.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}
