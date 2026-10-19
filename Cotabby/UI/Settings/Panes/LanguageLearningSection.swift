import SwiftUI

/// Presents the cross-language learning controls from the app-owned settings model.
/// The shared settings object owns persistence; the selected role only chooses visible Form
/// sections. Translation owns its directions and expression style; alignment owns its toggle/model
/// link. Both route technical configuration and shortcuts through the window's navigation.
struct LanguageLearningSection: View {
    @ObservedObject var settings: LanguageLearningSettings
    let role: LearningModelRole
    var configureModel: (LearningModelRole) -> Void = { _ in }
    var openShortcuts: () -> Void = {}
    var openApps: () -> Void = {}
    @State private var sourceLanguagesExpanded = false
    @Environment(\.settingsHighlightedItem) private var highlightedItem
    @Environment(\.settingsRevealSequence) private var revealSequence

    var body: some View {
        switch role {
        case .translation:
            translationSection
            selectionSection
            LearningTranslationStyleSection(profile: settings.translation)
        case .analysis:
            alignmentSection
        }
    }

    private var translationSection: some View {
        Section(String(localized: "Writing translation", table: "Learning",
            comment: "Settings section for language translation and sentence-learning controls.")) {
            Toggle(String(localized: "Enable expression translation", table: "Learning",
                comment: "Turns explicit translation previews on or off."),
                isOn: $settings.translationEnabled).settingsItem(.translationEnabled)
            Toggle(String(localized: "Show sentence expressions after a pause", table: "Learning",
                comment: "Automatically translates newly typed complete sentences after a brief pause."),
                isOn: $settings.sentencePreviewEnabled)
                .disabled(!settings.translationEnabled).settingsItem(.sentencePreview)
            translationControls
            Text(String(localized: """
            Translation sends the target, optional draft excerpts and style instructions to the chosen engine. Reading sends only selected, pointed or OCR-recognized \
            text and style instructions. Alignment receives the target and translation. Raw screenshots, unrelated clipboard content and history are excluded.
            """,
                table: "Learning", comment: """
                Privacy disclosure describing the data sent for learning requests and context that is never included.
                """))
                .font(.caption).foregroundStyle(.secondary)
            LearningModelSummaryRow(title: String(localized: "Translation model", table: "Learning",
                comment: "Name of the model profile used for translation."), profile: settings.translation) {
                configureModel(.translation)
            }
            LabeledContent {
                Button(String(localized: "Manage in Shortcuts", table: "Learning"), action: openShortcuts)
            } label: {
                Text(
                    String(
                        localized: "Translation shortcuts", table: "Learning", comment: "Read-only route to the central shortcut editor."))
            }
        }
    }

    private var selectionSection: some View {
        Section(String(localized: "Reading translation", table: "Learning")) {
            Toggle(String(localized: "Enable selection translation", table: "Learning"), isOn: $settings.selectionTranslationEnabled)
                .disabled(!settings.translationEnabled).settingsItem(.selectionTranslation)
            Toggle(String(localized: "Enable pointer translation", table: "Learning"), isOn: $settings.pointerTranslationEnabled)
                .disabled(!settings.translationEnabled).settingsItem(.pointerTranslation)
            Toggle(String(localized: "Enable screen region translation", table: "Learning"), isOn: $settings.screenshotTranslationEnabled)
                .disabled(!settings.translationEnabled).settingsItem(.screenshotTranslation)
            Picker(String(localized: "Reading target language", table: "Learning"), selection: $settings.readingTargetLanguage) {
                ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
            }.disabled(!settings.translationEnabled).settingsItem(.readingTargetLanguage)
            Toggle(String(localized: "Show selection translation icon", table: "Learning"), isOn: $settings.selectionIconEnabled)
                .disabled(!settings.translationEnabled || !settings.selectionTranslationEnabled).settingsItem(.selectionTranslationIcon)
            Button(String(localized: "Manage allowed apps", table: "Learning"), action: openApps)
                .settingsItem(.selectionTranslationApps)
            Button(String(localized: "Manage in Shortcuts", table: "Learning"), action: openShortcuts)
        }
    }

    private var alignmentSection: some View {
        Section(String(localized: "Chunk alignment", table: "Learning")) {
            if !settings.translationEnabled {
                Text(String(localized: "Enable translation in the Translation tab to use chunk alignment.", table: "Learning"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(String(localized: "Enable chunk alignment", table: "Learning",
                comment: "Turns source-to-translation phrase alignment on or off."),
                isOn: $settings.analysisEnabled)
                .disabled(!settings.translationEnabled).settingsItem(.chunkAlignment)
            Text(String(localized: """
            You can still read the translation, compare it with the source, and look up words when chunk alignment is off. Matching \
            only identifies corresponding excerpts; it does not translate again or generate explanations.
            """,
                table: "Learning", comment: "Explains the independent chunk-alignment setting and what its model does."))
                .font(.caption).foregroundStyle(.secondary)
            LearningModelSummaryRow(title: String(localized: "Chunk alignment model", table: "Learning",
                comment: "Name of the model profile used to align source and target phrases."), profile: settings.analysis) {
                configureModel(.analysis)
            }
        }
    }

    private var translationControls: some View {
        Group {
            Picker(
                String(
                    localized: "Translation reference", table: "Learning",
                    comment: "Selects extra translation context without changing the target."),
                selection: $settings.referenceMode
            ) {
                Text(String(localized: "Current sentence", table: "Learning", comment: "Translate without extra draft reference.")).tag(
                    LearningReferenceMode.currentSentence)
                Text(String(localized: "Draft context", table: "Learning", comment: "Use budgeted reference from the current draft.")).tag(
                    LearningReferenceMode.draft)
            }
            .settingsItem(.translationReferenceMode)
            Text(
                String(
                    localized:
                        "The target remains the current sentence or your selection. Only reference text may be shortened to fit the budget.",
                    table: "Learning", comment: "Distinguishes immutable translation target from bounded reference.")
            )
            .font(.caption).foregroundStyle(.secondary)
            Picker(String(localized: "Target language", table: "Learning",
                comment: "Picker label for the language to translate into."),
                selection: $settings.targetLanguage) {
                ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
            }.settingsItem(.translationTargetLanguage)
            DisclosureGroup(String(localized: "Source languages (optional; \(settings.sourceLanguages.count) selected)", table: "Learning",
                comment: "Disclosure label for source-language choices; the selected language count is inserted."),
                            isExpanded: sourceExpansionBinding) {
                ForEach(LearningLanguage.allCases) { language in
                    Toggle(language.label, isOn: Binding(
                        get: { settings.sourceLanguages.contains(language) },
                        set: { enabled in
                            settings.sourceLanguages.removeAll { $0 == language }
                            if enabled { settings.sourceLanguages.append(language) }
                        }
                    )).disabled(language == settings.targetLanguage)
                }
                Text(String(localized: """
                With one source language selected, translations follow that direction. With several selected, Lingrove detects the \
                language of each source; if it is uncertain, adjust the settings or select more text.
                """, table: "Learning", comment: "Explains fixed-direction translation versus automatic source-language detection."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsItem(.translationSourceLanguages)
            .onChange(of: revealSequence, initial: true) { _, _ in
                if highlightedItem == .translationSourceLanguages { sourceLanguagesExpanded = true }
            }
        }
    }

    /// Expansion is presentation state, not a persisted language preference. Its height change
    /// reaches the grouped Form and outer ScrollView; animating that change can repeatedly alter
    /// the scroller's document proportions. Apply the transaction at the binding write so the
    /// parent layout receives it too, without changing animations in other settings controls.
    private var sourceExpansionBinding: Binding<Bool> {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return $sourceLanguagesExpanded.transaction(transaction)
    }

}
/// Language Learning shows the role's current selection and a route into Engine & Model. It observes the
/// app-owned profile, while the navigation owner performs the jump. No model services or editable
/// server/key fields live in this summary, so there is one configuration surface per task.
private struct LearningModelSummaryRow: View {
    let title: String
    @ObservedObject var profile: LearningModelSettings
    let configure: () -> Void

    var body: some View {
        LabeledContent {
            Button(String(localized: "Configure model", table: "Learning",
                comment: "Opens Engine & Model settings for this learning model profile."), action: configure)
                .help(String(localized: "Configure \(title) in Engine & Model", table: "Learning",
                    comment: "Tooltip for opening this learning model profile's configuration."))
                .accessibilityLabel(String(localized: "Configure \(title)", table: "Learning",
                    comment: "VoiceOver label for opening this learning model profile's configuration."))
        } label: {
            SettingsRowLabel(title: title, description: summary, systemImage: "shippingbox")
        }
    }

    private var summary: String {
        let selection = profile.snapshot
        return switch selection.backend {
        case .local:
            selection.localModel.isEmpty
                ? String(localized: "Local GGUF · no model selected", table: "Learning",
                    comment: "Summary shown when the local backend is selected but this task has no GGUF model.")
                : String(localized: "Local GGUF · \(selection.localModel)", table: "Learning",
                    comment: "Summary of the local GGUF backend and selected model filename.")
        case .endpoint:
            selection.endpointModel.isEmpty
                ? String(localized: "Endpoint · no model entered", table: "Learning",
                    comment: "Summary shown when the endpoint backend is selected but its model identifier is empty.")
                : String(localized: "Endpoint · \(selection.endpointModel)", table: "Learning",
                    comment: "Summary of the endpoint backend and user-configured model identifier.")
        }
    }
}
