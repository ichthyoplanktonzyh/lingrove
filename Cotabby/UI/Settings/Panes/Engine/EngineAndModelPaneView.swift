import SwiftUI

/// File overview:
/// Fixed task tabs navigate among completion, translation, learning analysis, and TTS.
/// Each page uses the established grouped settings scaffold and app-owned services for its task.
/// Task pages show current configuration first. Resource management opens in a task-scoped
/// sheet, while technical options stay in collapsed sibling Form sections. Navigation belongs
/// to the settings window; all runtime, download and credential services remain app-owned.
struct EngineAndModelPaneView: View {
    @ObservedObject var navigation: SettingsNavigationModel
    var learningModels: LearningModelCollection?
    var speech: LearningSpeechController?
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var openAICompatibleConnectionModel: OpenAICompatibleConnectionModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var huggingFaceSearchService: HuggingFaceSearchService

    @State var pendingDeletionModel: RuntimeModelOption?
    @State var endpointAPIKeyDraft = ""
    @State var endpointCredentialError: String?
    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Model task", table: "Learning"), selection: Binding(
                get: { navigation.engineTask }, set: navigation.openEngineTask)) {
                ForEach(SettingsEngineTask.allCases) { task in Text(task.label).tag(task) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Model task", table: "Learning"))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            switch navigation.engineTask {
            case .completion:
                completionPage
            case .translation:
                learningPage(role: .translation)
            case .analysis:
                learningPage(role: .analysis)
            case .speech:
                speechPage
            }
        }
        .onAppear {
            // Optional sources must be reconciled even when only Endpoint/Apple sections are
            // visible; reinstalling LM Studio must not silently revive a removed source.
            if UserDefaults.standard.bool(forKey: BundledRuntimeLocator.lmStudioSourceEnabledKey),
               BundledRuntimeLocator.lmStudioModelsDirectoryIfAvailable() == nil {
                UserDefaults.standard.set(false, forKey: BundledRuntimeLocator.lmStudioSourceEnabledKey)
                modelDownloadManager.refreshSearchDirectories()
            }
        }
    }

    /// The completion form retains its services, actions and callout. Navigation tabs
    /// sit outside its scroll view so choosing another task cannot change the active engine.
    private var completionPage: some View {
        let contextIdentity = suggestionSettings.completionContextIdentity
        return SettingsPaneScaffold(callout: callout) {
            Section(String(localized: "Current configuration", table: "Learning")) {
                Picker(selection: selectedEngineBinding) {
                    // Match onboarding: an engine this Mac cannot run stays listed (so a stored
                    // selection still renders) but is greyed out and labelled, never selectable.
                    // `selectionDisabled` (macOS 14+) disables just that menu item.
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
                } label: {
                    SettingsRowLabel(
                        title: String(localized: "Run using", table: "Learning"),
                        description: String(localized: """
                        Apple Intelligence runs on-device using macOS's built-in model (newer Apple Silicon Macs only). Open Source \
                        runs a downloaded model file. Local Endpoint connects to an OpenAI-compatible server you manage.
                        """),
                        systemImage: "cpu"
                    )
                }
                .pickerStyle(.menu)
                .disabled(suggestionSettings.isPowerBasedModelSwitchingEnabled)
                .settingsItem(.engine)
                if suggestionSettings.isPowerBasedModelSwitchingEnabled {
                    Text(String(localized: "Model selection follows your power profiles in Advanced settings.", table: "Learning"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let item = navigation.revealedItem, let requested = searchEngine, requested != configurationEngine {
                    Button(String(localized: "Configure selected setting", table: "Learning")) {
                        navigation.inspectedCompletionEngine = requested
                        navigation.refreshReveal()
                    }.settingsItem(item)
                }
                if configurationEngine != suggestionSettings.selectedEngine {
                    Text(String(localized: "Viewing settings for \(configurationEngine.displayLabel).", table: "Learning"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(String(localized: "Return to current configuration", table: "Learning")) {
                        navigation.inspectedCompletionEngine = nil
                    }
                }
                modelManagementButton
            }

            switch configurationEngine {
            case .appleIntelligence:
                Section("Apple Intelligence") {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                }
            case .llamaOpenSource: openSourceSections
            case .openAICompatible:
                endpointModelSection
                endpointConnectionSection
            }
            SettingsAdvancedSections(isExpanded: navigation.advancedBinding(for: .completion)) {
                powerSection
                // Budget writes are keyed to the active model identity. Inspecting a dormant
                // backend exposes its connection controls, not another model's context budget.
                if configurationEngine == suggestionSettings.selectedEngine { ModelContextSection(
                    tokens: Binding(
                        get: { suggestionSettings.completionContextWindowTokens },
                        set: { suggestionSettings.setCompletionContextWindowTokens($0, expectedIdentity: contextIdentity) }),
                    maximum: suggestionSettings.selectedEngine == .appleIntelligence
                        ? 4_096
                        : suggestionSettings.selectedEngine == .llamaOpenSource
                            ? ModelContextBudget.maximumLocalTokens : ModelContextBudget.maximumEndpointTokens,
                    isEndpoint: suggestionSettings.selectedEngine == .openAICompatible,
                    isSystemManaged: suggestionSettings.selectedEngine == .appleIntelligence,
                    reset: { suggestionSettings.setCompletionContextWindowTokens(nil, expectedIdentity: contextIdentity) })
                    .id(contextIdentity) }

                if configurationEngine == .appleIntelligence { appleIntelligenceSections }
                if configurationEngine == .openAICompatible { endpointFormatSection }
            }
        }
        .onAppear {
            foundationModelAvailabilityService.refresh()

            suggestionSettings.initializePowerProfiles(
                currentEngine: suggestionSettings.selectedEngine,
                currentModelFilename: runtimeModel.selectedModelFilename,
                currentEndpointModelName: suggestionSettings.openAICompatibleModelName
            )

            loadEndpointAPIKey()
            if suggestionSettings.selectedEngine == .openAICompatible,
               openAICompatibleConnectionModel.state == .idle {
                refreshEndpointModels()
            }
        }
        .onChange(of: suggestionSettings.selectedEngine) { _, engine in
            navigation.inspectedCompletionEngine = nil
            if engine == .openAICompatible, openAICompatibleConnectionModel.state == .idle {
                refreshEndpointModels()
            }
        }
        .sheet(isPresented: navigation.modelManagerBinding(for: .completion)) {
            SettingsModelManagementSheet(task: .completion) { completionModelManagementSections }
            .onAppear(perform: refreshModels)
            .alert(
                String(localized: "Delete Model?"),
                isPresented: pendingDeletionAlertBinding,
                presenting: pendingDeletionModel
            ) { model in
                Button("Delete") { deleteModel(model) }
                Button("Cancel", role: .cancel) {}
            } message: { model in
                Text(String(localized: "Remove \(model.displayName) from Lingrove's local models folder?", table: "Learning"))
            }
        }
    }

    private var configurationEngine: SuggestionEngineKind {
        navigation.inspectedCompletionEngine ?? suggestionSettings.selectedEngine
    }

    private var searchEngine: SuggestionEngineKind? {
        switch navigation.revealedItem {
        case .appleIntelligenceAvailability, .appleLanguageFallback, .keepFallbackModelLoaded, .appleLanguageFallbackModel:
            .appleIntelligence
        case .endpointBaseURL, .endpointAPIMode, .endpointAPIKey, .endpointStatus, .endpointModel:
            .openAICompatible
        case .selectedModel, .modelStatus: .llamaOpenSource
        default: nil
        }
    }

    private func learningPage(role: LearningModelRole) -> some View {
        Group {
            if let learningModels {
                let controller = role == .translation ? learningModels.translation : learningModels.analysis
                LearningModelConfigurationView(controller: controller, profile: controller.profile, navigation: navigation,
                    suggestionSettings: suggestionSettings, downloads: modelDownloadManager, searchService: huggingFaceSearchService)
            } else {
                SettingsPaneScaffold {
                    Section("Runtime") { Text(String(localized: """
                    Learning model services are unavailable. Reopen Settings.
                    """, table: "Learning")) }
                }
            }
        }
        // Draft keys belong to a page's UI lifetime. Distinct identity prevents an unsaved
        // translation key from appearing in the analysis form when switching between tasks.
        .id(role)
    }

    /// Speech stays a distinct task so voice management does not inherit translation's model
    /// controls. Its app-owned controller routes system, local-model and endpoint speech;
    /// this page only edits preferences and requests explicit auditions.
    private var speechPage: some View {
        Group {
            if let speech {
                SpeechConfigurationView(speech: speech, navigation: navigation)
            } else {
                SettingsPaneScaffold {
                    Section(String(localized: "TTS", table: "Learning")) {
                        Text(String(localized: "Speech settings are unavailable. Reopen Settings to try again.", table: "Learning"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
