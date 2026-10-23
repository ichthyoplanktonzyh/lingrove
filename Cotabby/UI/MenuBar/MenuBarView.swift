import AppKit
import SwiftUI

/// File overview:
/// Composes Cotabby's primary menu-bar control panel as a status-first surface
/// with inline quick controls for session-level preferences.
///
/// Design philosophy: the menu bar is the primary interaction surface for a menu bar app.
/// It shows status at a glance in the header, groups session controls into calm Control-Center-style
/// surface cards, and exposes the controls users reach for mid-session (engine, model, completion
/// length, translation toggles). Rarely-changed settings (model management, profile personalization,
/// updates) live in the Settings window.
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
                .padding(.bottom, 10)

            Picker(
                String(localized: "Quick controls", table: "Learning"),
                selection: Binding(get: { presentation.selectedTask }, set: presentation.select)
            ) {
                ForEach(MenuBarTask.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 10)
            .accessibilityIdentifier("menuBarTask")

            VStack(alignment: .leading, spacing: 0) {
                switch presentation.displayedTask {
                case .completion:
                    // Keep the completion content in its natural, non-scrolling layout.
                    controlsSection
                    permissionsCard
                case .learning:
                    MenuBarContentViewport(maximumHeight: presentation.maximumLearningHeight) {
                        VStack(alignment: .leading, spacing: 0) {
                            MenuBarLearningControls(
                                settings: suggestionSettings.languageLearning,
                                speech: speech,
                                screenRecordingGranted: permissionManager.screenRecordingGranted,
                                open: openDestination,
                                review: openReview
                            )
                            .padding(.bottom, 10)
                            permissionsCard
                        }
                    }
                }
            }
            // Fade and subtly settle the page body only. The header and picker keep their identity
            // and top position while MenuBarController resizes the native popover container.
            .opacity(presentation.pageVisible ? 1 : 0)
            .blur(radius: presentation.pageVisible || presentation.reduceMotion ? 0 : 1.2)
            .offset(y: presentation.pageVisible || presentation.reduceMotion ? 0 : -2)
            .animation(
                presentation.reduceMotion ? nil : .easeOut(duration: 0.12),
                value: presentation.pageVisible
            )
            .allowsHitTesting(presentation.pageVisible)
            .accessibilityHidden(!presentation.pageVisible)

            footerSection
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(
                key: MenuBarContentMeasurementKey.self,
                value: MenuBarContentMeasurement(page: presentation.displayedTask, size: geometry.size)
            )
        })
        .onPreferenceChange(MenuBarContentMeasurementKey.self) { measurement in
            if let measurement { presentation.onMeasure?(measurement) }
        }
    }

    // MARK: - Header & Global Activation

    /// Top identity and status bar. Putting global pause/resume in the header makes it reachable
    /// from both tabs without duplicating rows, and immediately communicates whether Lingrove is
    /// active, loading a model, or paused.
    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [CotabbyBrand.accentSoft, CotabbyBrand.accent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Image("MenuBarWhaleIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
                .shadow(color: CotabbyBrand.accent.opacity(0.25), radius: 3, y: 1)
                .accessibilityHidden(true)

                Text(ProductIdentity.appDisplayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                if let appShortVersion {
                    Text(appShortVersion)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(.quaternary.opacity(0.65), in: Capsule())
                        .accessibilityLabel("Version \(appShortVersion)")
                }

                Spacer(minLength: 4)

                activationPill
            }

            if isInactiveOrPaused {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if let pauseStatus = suggestionSettings.pauseStatusText {
                        Text(pauseStatus)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(String(localized: "Lingrove is turned off", table: "Learning"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.24), lineWidth: 0.5)
                )
            }
        }
    }

    /// Global pause/resume pill in the header. While active, it offers bounded and manual pause
    /// durations; while paused or globally disabled, it switches to a single recovery action so
    /// the user cannot stack contradictory disable states.
    @ViewBuilder
    private var activationPill: some View {
        if isInactiveOrPaused {
            Button {
                suggestionSettings.enableCotabby()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(String(localized: "Enable Lingrove", table: "Learning"))
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.14))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                ForEach(SuggestionPauseDuration.allCases) { duration in
                    Button(duration.menuLabel) {
                        suggestionSettings.pauseSuggestions(for: duration)
                    }
                }
            } label: {
                Label(String(localized: "Pause Lingrove", table: "Learning"), systemImage: "pause.fill")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var isInactiveOrPaused: Bool {
        suggestionSettings.isTemporarilyPaused || !suggestionSettings.isGloballyEnabled
    }

    /// Short, user-facing app version (e.g. "0.4.2-beta") shown next to the title. Reads the bundle's
    /// `CFBundleShortVersionString`, the same canonical source the About pane uses.
    private var appShortVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Autocomplete Quick Controls

    /// Session-level preferences that users reach for mid-work: completion & context toggles in one
    /// surface card, and engine / model / length selection in a second surface card.
    @ViewBuilder
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuBarSurfaceCard(padding: 10, spacing: 8) {
                MenuBarToggleRow(
                    title: String(localized: "Autocomplete"),
                    systemImage: "sparkles",
                    isOn: Binding(
                        get: { suggestionSettings.isCompletionEnabled },
                        set: suggestionSettings.setCompletionEnabled
                    ),
                    identifier: "menuCompletionEnabled"
                )

                MenuBarCardDivider()

                MenuBarToggleRow(
                    title: String(localized: "Include Clipboard Context"),
                    systemImage: "doc.on.clipboard",
                    isOn: clipboardContextEnabledBinding
                )

                MenuBarToggleRow(
                    title: String(localized: "Use screen context"),
                    systemImage: "macwindow",
                    subtitle: screenContextUnavailable
                        ? String(localized: "Unavailable while Screen Recording is off")
                        : nil,
                    isOn: screenContextUnavailable ? .constant(false) : screenContextEnabledBinding,
                    isDisabled: screenContextUnavailable
                )
            }

            MenuBarSurfaceCard(padding: 10, spacing: 8) {
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
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(foundationModelAvailabilityService.userVisibleMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if suggestionSettings.selectedEngine.supportsLocalModelManagement {
                    MenuBarCardDivider()
                    modelRow
                }

                MenuBarCardDivider()

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
        .padding(.bottom, 10)
    }

    /// Model selector with folder + refresh shortcuts — only visible when local llama engine is active.
    /// The picker is constrained to fill remaining row width so long filenames truncate inside the
    /// NSPopUpButton label instead of pushing the trailing icons off-row.
    @ViewBuilder
    private var modelRow: some View {
        MenuBarPickerRow(title: String(localized: "Model")) {
            HStack(spacing: 4) {
                if runtimeModel.availableModels.isEmpty {
                    Text("No models found")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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

                MenuBarIconButton(
                    systemImage: "folder",
                    helpText: String(localized: "Show Models in Finder")
                ) {
                    modelDownloadManager.openModelsDirectory()
                }

                MenuBarIconButton(
                    systemImage: "arrow.clockwise",
                    helpText: String(localized: "Refresh Models")
                ) {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                }
            }
        }
    }

    // MARK: - Permissions (conditional)

    /// Lists every permission Cotabby can use and appears whenever at least one is missing, including
    /// the optional Screen Recording enhancement. Each row carries its own grant state, so the card
    /// keeps showing the still-missing permission until nothing is left to grant, then vanishes.
    @ViewBuilder
    private var permissionsCard: some View {
        if !allPermissionsGranted {
            MenuBarSurfaceCard(padding: 10, spacing: 6, tint: .orange) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Permissions")
                        .font(.subheadline.weight(.medium))
                }
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
            .padding(.bottom, 10)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuBarSurfaceCard(padding: 4, spacing: 2) {
                Button {
                    presentation.dismiss()
                    onOpenVocabulary()
                } label: {
                    HStack(spacing: 8) {
                        VocabularyFavoriteIcon(isSaved: true)
                            .frame(width: 16, height: 16)
                        Text(String(localized: "Vocabulary", table: "Vocabulary") + "…")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuBarInteractiveRowButtonStyle())

                MenuBarActionRow(
                    title: String(localized: "Settings"),
                    systemImage: "gearshape",
                    iconTint: .secondary,
                    trailingText: "⌘,",
                    showsChevron: false
                ) {
                    // Dismiss the popover before opening the Settings window so the popover doesn't
                    // remain on top of (and obscure) the Settings pane. See issue #455.
                    presentation.dismiss()
                    onOpenSettings()
                }
            }

            HStack(spacing: 4) {
                Button("Check for Updates") {
                    appUpdateManager.checkForUpdates()
                }
                .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 6, verticalPadding: 3, cornerRadius: 5))

                Text("·")
                    .foregroundStyle(.quaternary)
                    .accessibilityHidden(true)

                Button("Report Bug", action: onReportFeedback)
                    .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 6, verticalPadding: 3, cornerRadius: 5))

                Text("·")
                    .foregroundStyle(.quaternary)
                    .accessibilityHidden(true)

                Link("GitHub", destination: ProductIdentity.repositoryURL)
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)

                Spacer(minLength: 0)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 6, verticalPadding: 3, cornerRadius: 5))
                .keyboardShortcut("q")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
