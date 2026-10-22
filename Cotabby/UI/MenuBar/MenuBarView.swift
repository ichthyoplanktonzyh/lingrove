import AppKit
import SwiftUI

/// File overview:
/// Composes Cotabby's primary menu-bar control panel as a status-first surface
/// with inline quick controls for session-level preferences.
///
/// Design philosophy: the menu bar is the primary interaction surface for a menu bar app.
/// It shows status at a glance and exposes the controls users reach for mid-session
/// (engine, model, completion length). Rarely-changed settings (model management,
/// profile personalization, updates) live in the Settings window.
///
/// The focused-app context card was intentionally removed: opening the menu bar panel
/// steals focus from whatever app the user was typing in, so live focus state is always
/// stale by the time the panel renders.
struct MenuBarView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var focusModel: FocusTrackingModel
    let permissionGuidanceController: PermissionGuidanceController
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var powerSourceMonitor: PowerSourceMonitor
    let speech: LearningSpeechController
    let appUpdateManager: AppUpdateManager
    let onOpenSettings: () -> Void
    let onReportFeedback: () -> Void
    var onOpenVocabulary: () -> Void = {}
    var onOpenReview: () -> Void = {}
    var onOpenDestination: (MenuBarSettingsDestination) -> Void = { _ in }

    @ObservedObject var presentation: MenuBarPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.bottom, 12)
            Picker(String(localized: "Quick controls", table: "Learning"),
                   selection: Binding(get: { presentation.selectedTask }, set: presentation.select)) {
                ForEach(MenuBarTask.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.bottom, 12)
            .accessibilityIdentifier("menuBarTask")
            VStack(alignment: .leading, spacing: 0) {
                switch presentation.displayedTask {
                case .completion:
                    // Keep the original completion content in its natural, non-scrolling layout.
                    controlsSection
                    permissionsCard
                case .learning:
                    activationControls.padding(.bottom, 8)
                    Divider().padding(.bottom, 8)
                    MenuBarContentViewport(maximumHeight: presentation.maximumLearningHeight) {
                        VStack(alignment: .leading, spacing: 0) {
                            MenuBarLearningControls(settings: suggestionSettings.languageLearning, speech: speech,
                                screenRecordingGranted: permissionManager.screenRecordingGranted,
                                open: openDestination, review: openReview)
                                .padding(.bottom, 12)
                            permissionsCard
                        }
                    }
                }
            }
            // Fade the page body only. The header and picker keep their identity and top position.
            .opacity(presentation.pageVisible ? 1 : 0)
            .animation(presentation.reduceMotion ? nil : .easeOut(duration: 0.08), value: presentation.pageVisible)
            .allowsHitTesting(presentation.pageVisible)
            .accessibilityHidden(!presentation.pageVisible)
            footerSection
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MenuBarContentMeasurementKey.self,
                value: MenuBarContentMeasurement(page: presentation.displayedTask, size: geometry.size))
        })
        .onPreferenceChange(MenuBarContentMeasurementKey.self) { measurement in
            if let measurement { presentation.onMeasure?(measurement) }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .center) {
            Text(ProductIdentity.appDisplayName)
                .font(.headline)

            if let appShortVersion {
                Text(appShortVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Version \(appShortVersion)")
            }

            // A plain source link keeps project information separate from the product title.
            Link("GitHub", destination: ProductIdentity.repositoryURL)
                .buttonStyle(.borderless)
                .font(.subheadline)

            Spacer(minLength: 0)

            Button("Report Bug", action: onReportFeedback)
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
        .padding(.bottom, 12)
    }

    /// Short, user-facing app version (e.g. "0.4.2-beta") shown next to the title. Reads the bundle's
    /// `CFBundleShortVersionString`, the same canonical source the About pane uses.
    private var appShortVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Quick controls

    /// The original pause/recovery children are shared without adding a layout container.
    /// Their spacing remains owned by each page, so completion keeps its pre-learning layout.
    @ViewBuilder
    private var activationControls: some View {
        // Activation lives in its own band. While active, the menu offers bounded and manual
        // pauses. While paused or globally disabled, those choices are replaced by one recovery
        // action so the user cannot accidentally stack contradictory disable states.
        Group {
            if suggestionSettings.isTemporarilyPaused || !suggestionSettings.isGloballyEnabled {
                Button {
                    suggestionSettings.enableCotabby()
                } label: {
                    Label(String(localized: "Enable Lingrove", table: "Learning"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                if let pauseStatus = suggestionSettings.pauseStatusText {
                    Text(pauseStatus)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(String(localized: "Lingrove is turned off", table: "Learning"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Menu {
                    ForEach(SuggestionPauseDuration.allCases) { duration in
                        Button(duration.menuLabel) {
                            suggestionSettings.pauseSuggestions(for: duration)
                        }
                    }
                } label: {
                    Label(String(localized: "Pause Lingrove", table: "Learning"), systemImage: "pause.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Session-level preferences that users reach for mid-work: engine choice,
    /// model selection (when using local llama), and completion length.
    @ViewBuilder
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            activationControls

            Toggle("Autocomplete", isOn: Binding(get: { suggestionSettings.isCompletionEnabled },
                set: suggestionSettings.setCompletionEnabled))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("menuCompletionEnabled")

            Divider()

            // Context-shaping toggles that change what the model is fed.
            Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Use screen context", isOn: screenContextUnavailable ? .constant(false) : screenContextEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(screenContextUnavailable)

                if screenContextUnavailable {
                    Text("Unavailable while Screen Recording is off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Generation setup: which engine/model produces completions and how long they run.
            // Wrapped in a Group so the four rows plus the toggles and dividers above stay under
            // SwiftUI's 10-child ViewBuilder limit for the enclosing VStack.
            Group {
                MenuBarPickerRow(title: String(localized: "Engine")) {
                    Picker("Engine", selection: selectedEngineBinding) {
                        // Same gating as Settings and onboarding: an unavailable engine is shown
                        // greyed out with an "(Unavailable)" suffix and cannot be picked.
                        ForEach(SuggestionEngineKind.allCases) { engine in
                            Text(
                                SuggestionEngineSelectionPolicy.pickerLabel(
                                    for: engine,
                                    foundationModelAvailable: foundationModelAvailabilityService.isAvailable
                                )
                            )
                            .tag(engine)
                            .selectionDisabled(!isEngineSelectable(engine))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if suggestionSettings.selectedEngine == .appleIntelligence,
                   !foundationModelAvailabilityService.isAvailable {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if suggestionSettings.selectedEngine.supportsLocalModelManagement {
                    modelRow
                }

                MenuBarPickerRow(title: String(localized: "Length")) {
                    Picker("Length", selection: lengthChoiceBinding) {
                        ForEach(SuggestionWordCountPreset.allCases) { preset in
                            Text(preset.displayLabel)
                                .tag(LengthChoice.preset(preset))
                        }
                        // The custom range stays editable from the Writing settings pane; selecting
                        // it here just flips the active mode and surfaces the current numbers so the
                        // user can tell at a glance which budget is in force.
                        Text("Custom (\(customRangeCompactLabel))")
                            .tag(LengthChoice.custom)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

            }
        }
        .padding(.bottom, 12)
    }

    /// Model selector with folder + refresh shortcuts — only visible when local llama engine is active.
    /// The picker is constrained to fill remaining row width so long filenames truncate inside the
    /// NSPopUpButton label instead of pushing the trailing icons off-row. Per-item `.lineLimit` /
    /// `.truncationMode` modifiers are unreliable here because AppKit's native popup ignores them
    /// for the selected-value label.
    @ViewBuilder
    private var modelRow: some View {
        MenuBarPickerRow(title: String(localized: "Model")) {
            HStack(spacing: 6) {
                if runtimeModel.availableModels.isEmpty {
                    Text("No models found")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    Picker("Model", selection: selectedModelBinding) {
                        ForEach(runtimeModel.availableModels) { model in
                            Text(model.displayName)
                                .tag(model.filename)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .disabled(runtimePickerDisabled)
                }

                Button {
                    modelDownloadManager.openModelsDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Button {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Permissions (conditional)

    /// Lists every permission Cotabby can use and appears whenever at least one is missing, including
    /// the optional Screen Recording enhancement. Each row carries its own grant state, so the card
    /// keeps showing the still-missing permission until nothing is left to grant, then vanishes.
    /// Screen Recording is surfaced as a normal "(Optional)" permission row rather than hidden or
    /// shown as a feature toggle, but it never blocks autocomplete (see
    /// `CotabbyPermissionKind.isRequiredForAutocomplete`).
    @ViewBuilder
    private var permissionsCard: some View {
        if !allPermissionsGranted {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.subheadline.weight(.medium))
                    .padding(.bottom, 2)

                ForEach(CotabbyPermissionKind.allCases) { permission in
                    PermissionRow(
                        title: permission.compactRowTitle,
                        granted: permissionManager.isGranted(permission),
                        action: { sourceFrameInScreen in
                            permissionGuidanceController.requestAccess(
                                for: permission,
                                sourceFrameInScreen: sourceFrameInScreen
                            )
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        Divider()
            .padding(.bottom, 10)

        Button {
            presentation.dismiss()
            onOpenVocabulary()
        } label: {
            HStack(spacing: 7) {
                VocabularyFavoriteIcon(isSaved: true).frame(width: 18, height: 18)
                Text(String(localized: "Vocabulary", table: "Vocabulary") + "…")
            }
        }.buttonStyle(.borderless).padding(.bottom, 10)

        HStack {
            Button("Settings") {
                // Dismiss the popover before opening the Settings window so the popover doesn't
                // remain on top of (and obscure) the Settings pane. See issue #455.
                presentation.dismiss()
                onOpenSettings()
            }
            .buttonStyle(.borderless)

            Button("Check for Updates") {
                appUpdateManager.checkForUpdates()
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.subheadline)
    }

    // MARK: - Bindings

    private func openDestination(_ destination: MenuBarSettingsDestination) {
        presentation.dismiss()
        onOpenDestination(destination)
    }

    private func openReview() {
        presentation.dismiss()
        onOpenReview()
    }

    private var clipboardContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isClipboardContextEnabled },
            set: { suggestionSettings.setClipboardContextEnabled($0) }
        )
    }

    /// Keep the positive UI control compatible with the existing inverse stored preference.
    private var screenContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { !suggestionSettings.isFastModeEnabled },
            set: { suggestionSettings.setFastModeEnabled(!$0) }
        )
    }

    private func isEngineSelectable(_ engine: SuggestionEngineKind) -> Bool {
        SuggestionEngineSelectionPolicy.isSelectable(
            engine,
            foundationModelAvailable: foundationModelAvailabilityService.isAvailable
        )
    }

    private var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { engine in
                // Never persist an engine this Mac cannot run, as a guard behind the disabled item.
                guard isEngineSelectable(engine) else { return }
                // With power-based switching on, the active engine is owned by the current power
                // source's profile. Editing it here writes that profile (battery vs. plugged-in)
                // instead of `selectedEngine`, which the switcher would otherwise revert. The profile
                // carries engine + model, so an Apple Intelligence pick drops the model and an Open
                // Source pick keeps the currently selected one.
                guard suggestionSettings.isPowerBasedModelSwitchingEnabled else {
                    suggestionSettings.selectEngine(engine)
                    return
                }
                let profile: PowerProfile
                switch engine {
                case .appleIntelligence:
                    profile = .appleIntelligence
                case .llamaOpenSource:
                    profile = .llama(filename: runtimeModel.selectedModelFilename ?? "")
                case .openAICompatible:
                    profile = .openAICompatible(modelName: suggestionSettings.openAICompatibleModelName)
                }
                applyProfileForCurrentPowerSource(profile)
            }
        )
    }

    /// One of the curated presets or the user's custom range. Backed by two pieces of state
    /// (`selectedWordCountPreset` + `isUsingCustomWordCountRange`) so the menu can render and
    /// mutate both with a single picker.
    private enum LengthChoice: Hashable {
        case preset(SuggestionWordCountPreset)
        case custom
    }

    private var lengthChoiceBinding: Binding<LengthChoice> {
        Binding(
            get: {
                suggestionSettings.isUsingCustomWordCountRange
                    ? .custom
                    : .preset(suggestionSettings.selectedWordCountPreset)
            },
            set: { choice in
                switch choice {
                case let .preset(preset):
                    suggestionSettings.setUsingCustomWordCountRange(false)
                    suggestionSettings.selectWordCountPreset(preset)
                case .custom:
                    suggestionSettings.setUsingCustomWordCountRange(true)
                }
            }
        )
    }

    private var customRangeCompactLabel: String {
        SuggestionWordRange.clamped(
            low: suggestionSettings.customWordCountLowWords,
            high: suggestionSettings.customWordCountHighWords
        ).compactLabel
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                runtimeModel.selectedModelFilename
                    ?? runtimeModel.availableModels.first?.filename
                    ?? ""
            },
            set: { filename in
                // With power-based switching on, write the model into the current power source's
                // profile so it sticks for that source (and the other source keeps its own model).
                // Calling `selectModel` directly would be reverted by the power switcher on its next
                // evaluation, which read as "the popup just resets my choice".
                guard suggestionSettings.isPowerBasedModelSwitchingEnabled else {
                    Task {
                        await runtimeModel.selectModel(filename)
                    }
                    return
                }
                applyProfileForCurrentPowerSource(.llama(filename: filename))
            }
        )
    }

    /// Writes a profile into whichever per-power-source slot is currently active, so a menu-bar edit
    /// updates the battery profile while on battery and the plugged-in profile while charging. The
    /// power-source observer then applies it to the runtime, so no direct `selectModel`/`selectEngine`
    /// call is needed here.
    private func applyProfileForCurrentPowerSource(_ profile: PowerProfile) {
        if powerSourceMonitor.isPluggedIn {
            suggestionSettings.setPluggedInProfile(profile)
        } else {
            suggestionSettings.setBatteryProfile(profile)
        }
    }

    private var runtimePickerDisabled: Bool {
        switch runtimeModel.state {
        case .starting, .loading:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    // MARK: - Derived state

    private var allPermissionsGranted: Bool {
        permissionManager.allPermissionsGranted
    }

    /// Permission availability changes the displayed state without overwriting the user's choice.
    /// Granting Screen Recording restores that choice through the settings model.
    private var screenContextUnavailable: Bool {
        !permissionManager.screenRecordingGranted
    }

}

/// The measurement carries the page identity so a deferred layout from an outgoing page cannot
/// resize the new one. Geometry is measured before the native container clips its content.
private struct MenuBarContentMeasurementKey: PreferenceKey {
    static let defaultValue: MenuBarContentMeasurement? = nil
    static func reduce(value: inout MenuBarContentMeasurement?, nextValue: () -> MenuBarContentMeasurement?) {
        if let next = nextValue() { value = next }
    }
}
