import SwiftUI

/// One learning task's form sections use the same scaffold and native row controls as completion.
/// The app owns its controller/profile; this view owns only an unsaved key draft and connect state.
/// Switching task tabs changes view identity, keeping draft keys out of the other role's form.
struct LearningModelConfigurationView: View {
    @ObservedObject var controller: LearningModelController
    @ObservedObject var profile: LearningModelSettings
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    var downloads: ModelDownloadManager?
    var searchService: HuggingFaceSearchService?
    @State private var apiKey = ""
    @State private var credentialError: String?
    @State private var pendingDeletion: RuntimeModelOption?

    var body: some View {
        let contextIdentity = profile.contextIdentity
        return SettingsPaneScaffold {
            Section(String(localized: "Current configuration", table: "Learning")) {
                Picker(selection: backendBinding) {
                    ForEach(LearningModelBackend.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingsRowLabel(title: String(localized: "Run using", table: "Learning"),
                        description: taskDescription, systemImage: "cpu")
                }
                .pickerStyle(.menu).disabled(profile.powerSwitchingEnabled)
                if profile.powerSwitchingEnabled {
                    Text(String(localized: "Model selection follows your power profiles in Advanced settings.", table: "Learning"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if downloads != nil {
                    Button(String(localized: "Manage models", table: "Learning")) { navigation.openModelManager(task) }
                }
            }
            switch profile.snapshot.backend {
            case .local: localSelectionSection
            case .endpoint:
                endpointModelSection
                endpointConnectionSection
            }
            SettingsAdvancedSections(isExpanded: navigation.advancedBinding(for: task)) {
                powerSection
                if profile.role == .translation {
                    ModelContextSection(
                        tokens: Binding(get: { profile.snapshot.contextWindowTokens },
                            set: { profile.setContextWindowTokens($0, expectedIdentity: contextIdentity) }),
                        maximum: profile.snapshot.backend == .local
                            ? ModelContextBudget.maximumLocalTokens : ModelContextBudget.maximumEndpointTokens,
                        isEndpoint: profile.snapshot.backend == .endpoint,
                        reset: { profile.setContextWindowTokens(nil, expectedIdentity: contextIdentity) })
                        .id(contextIdentity)
                }
                if profile.role == .translation {
                    ModelSamplingSection(overrides: Binding(get: { profile.generationProfile.sampling }, set: {
                        var value = profile.generationProfile; value.sampling = $0
                        profile.setGenerationProfile(value, expectedIdentity: contextIdentity)
                    }), recommended: profile.recommendedSampling ?? LearningInstructionSampling.standard.values,
                        local: profile.snapshot.backend == .local, item: .translationSampling)
                    .id(contextIdentity + ".sampling").disabled(profile.recommendedSampling == nil)
                }
                if profile.snapshot.backend == .local { instructionTemplateSection }
            }
        }
        .onAppear {
            controller.refreshModels()
            do { apiKey = try profile.apiKey() ?? ""; credentialError = nil } catch { credentialError = error.localizedDescription }
            if profile.snapshot.backend == .endpoint, controller.endpointConnection.state == .idle {
                Task { await controller.discoverEndpoint() }
            }
        }
        .onChange(of: profile.snapshot.backend) { _, backend in
            if backend == .endpoint, controller.endpointConnection.state == .idle {
                Task { await controller.discoverEndpoint() }
            }
        }
        .sheet(isPresented: navigation.modelManagerBinding(for: task)) {
            SettingsModelManagementSheet(task: task) { modelManagementSections }
            .onAppear(perform: refreshModels)
            .alert(String(localized: "Delete model?", table: "Learning",
                comment: "Confirmation alert shown before removing a local model file."),
                isPresented: Binding(get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { model in
                Button(String(localized: "Delete", table: "Learning",
                    comment: "Confirms removing a downloaded local model.")) {
                    downloads?.deleteModel(filename: model.filename); refreshModels(); pendingDeletion = nil
                }
                Button(String(localized: "Cancel", table: "Learning",
                    comment: "Cancels removing a downloaded local model."), role: .cancel) { pendingDeletion = nil }
            } message: { model in
                Text(String(
                    localized: "Remove \(model.displayName) from Lingrove's local models folder?",
                    table: "Learning",
                    comment: "Confirmation message naming the local model file that will be removed."
                ))
            }
        }
    }

    private var taskDescription: String {
        profile.role == .translation
            ? String(localized: """
            Choose a local GGUF or a separate endpoint for sentence translation. A translation-focused model is recommended.
            """,
                table: "Learning", comment: "Description of the translation task's engine setting.")
            : String(localized: """
            Choose a local instruction-tuned GGUF or a separate endpoint for chunk alignment. Only confirmed source and translation \
            text is aligned.
            """,
                table: "Learning", comment: "Description of the chunk-alignment task's engine setting.")
    }

    private var task: SettingsEngineTask { SettingsEngineTask(role: profile.role) }
    private var modelItem: SettingsItem { profile.role == .translation ? .translationModel : .alignmentModel }

    /// A saved choice does not mean the task has loaded native weights. Loading is intentionally
    /// deferred until a real request; the status makes that lifecycle visible without starting it.
    private var localStatus: String {
        if controller.status == String(localized: "Not loaded", table: "Learning"),
           controller.availableModels.contains(where: { $0.filename == profile.snapshot.localModel }) {
            return String(localized: "Configured · loads on first use", table: "Learning")
        }
        return controller.status
    }

    private var localSelectionSection: some View {
        Section(String(localized: "Model", table: "Learning")) {
            Picker(selection: localModelBinding) {
                Text(String(localized: "Choose a model", table: "Learning")).tag("")
                if !profile.snapshot.localModel.isEmpty,
                   !controller.availableModels.contains(where: { $0.filename == profile.snapshot.localModel }) {
                    Text(String(localized: "\(profile.snapshot.localModel) (file unavailable)", table: "Learning"))
                        .tag(profile.snapshot.localModel)
                }
                ForEach(controller.availableModels) { Text($0.displayName).tag($0.filename) }
            } label: {
                SettingsRowLabel(title: String(localized: "Selected model", table: "Learning"),
                    description: String(localized: "Choose from downloaded or imported GGUF files.", table: "Learning"),
                    systemImage: "shippingbox")
            }
            .pickerStyle(.menu).disabled(profile.powerSwitchingEnabled).settingsItem(modelItem)
            LabeledContent(String(localized: "Model status", table: "Learning"), value: localStatus)
        }
    }

    private var instructionTemplateSection: some View {
        Section(String(localized: "Instruction template", table: "Learning")) {
            Picker(selection: templateBinding) {
                ForEach(LearningChatTemplate.available(for: profile.role)) { Text($0.label).tag($0) }
            } label: {
                SettingsRowLabel(title: String(localized: "Instruction template", table: "Learning"),
                    description: String(localized:
                        "Detected automatically by default. Choose one manually for renamed models or unusual variants.",
                        table: "Learning"), systemImage: "text.alignleft")
            }
            .pickerStyle(.menu).disabled(profile.powerSwitchingEnabled)
        }
    }

    @ViewBuilder
    private var modelManagementSections: some View {
        if let downloads {
            if !controller.availableModels.isEmpty {
                Section(String(localized: "Installed", table: "Learning")) {
                    ForEach(controller.availableModels) { model in
                        InstalledRuntimeModelRow(model: model, selected: model.filename == profile.snapshot.localModel,
                            downloads: downloads,
                            select: profile.powerSwitchingEnabled ? nil : { profile.localModel = model.filename },
                            delete: { pendingDeletion = model })
                    }
                }
            }
            Section(String(localized: "Get models", table: "Learning")) {
                DownloadableModelCatalogView(modelDownloadManager: downloads, onRefreshModels: refreshModels,
                    catalog: profile.role == .translation ? LearningRuntimeCatalog.translationModels : LearningRuntimeCatalog.analysisModels)
                if let searchService {
                    HuggingFaceModelBrowserView(searchService: searchService,
                        modelDownloadManager: downloads, onRefreshModels: refreshModels)
                }
            }
            ModelsFolderSection(downloads: downloads, refresh: refreshModels)
        }
    }

    private var endpointModelSection: some View {
        Section(String(localized: "Model", table: "Learning",
            comment: "Settings section for the endpoint model identifier used by this learning task.")) {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("", text: endpointModelBinding,
                        prompt: Text(String(localized: "Enter model identifier", table: "Learning",
                            comment: "Placeholder for the configured endpoint model name or identifier.")))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320).disabled(profile.powerSwitchingEnabled)
                    Menu {
                        ForEach(controller.endpointConnection.models) { option in
                            Button(option.id) { profile.endpointModel = option.id }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down").frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(controller.endpointConnection.models.isEmpty || profile.powerSwitchingEnabled)
                    .help(String(localized: "Connect to choose a model, or enter an identifier manually.", table: "Learning",
                        comment: "Tooltip explaining that endpoint models can be discovered or entered manually."))
                    .accessibilityLabel(String(localized: "Choose endpoint model", table: "Learning",
                        comment: "VoiceOver label for opening the list of discovered endpoint models."))
                }
            } label: {
                SettingsRowLabel(title: String(localized: "Model", table: "Learning",
                    comment: "Label for the endpoint model identifier used by this learning task."),
                    description: String(localized: "Endpoint model name used only for this task.",
                        table: "Learning", comment: "Explains that this endpoint model choice is independent of other tasks."),
                    systemImage: "shippingbox")
            }
            .settingsItem(modelItem)
            LabeledContent(String(localized: "API format", table: "Learning",
                comment: "Label for the API request format used by this learning endpoint."),
                value: String(localized: "Chat Completions", table: "Learning",
                    comment: "OpenAI-compatible chat-completions API format."))
        }
    }

    private var endpointConnectionSection: some View {
        ModelEndpointConnectionSection(baseURL: $profile.baseURL, keyDraft: $apiKey,
            connection: controller.endpointConnection, credentialError: credentialError,
            privacyWarning: privacyWarning,
            transmissionNote: profile.role == .translation
                ? String(localized: """
                    With this endpoint, the service receives the target, language direction, optional draft excerpts and style instructions.
                    """,
                    table: "Learning", comment: "Disclosure of what the configured endpoint receives for translation requests.")
                : String(localized: """
                With this endpoint, the service receives the current source text, displayed translation, and language direction.
                """,
                    table: "Learning", comment: "Disclosure of what the configured endpoint receives for chunk-alignment requests."),
            connect: {
                let draft = apiKey
                Task { await controller.connect(using: draft); credentialError = nil }
            },
            reset: controller.resetEndpointBaseURL,
            clearKey: {
                apiKey = ""
                credentialError = profile.saveAPIKey(nil) ? nil : profile.credentialMessage
            })
    }
    private var privacyWarning: String? {
        guard let config = try? OpenAICompatibleEndpointConfiguration(baseURLString: profile.baseURL,
            modelName: profile.endpointModel, apiMode: .chatCompletions), config.hostScope != .loopback else { return nil }
        return config.hostScope == .publicInternet
            ? String(localized: "With this endpoint, this text is sent to the configured HTTPS remote service.",
                table: "Learning", comment: "Privacy notice shown when the learning endpoint uses a public HTTPS host.")
            : String(localized: "With this endpoint, this text is sent to the configured local-network service.",
                table: "Learning", comment: "Privacy notice shown when the learning endpoint uses a LAN host.")
    }
    private var backendBinding: Binding<LearningModelBackend> {
        Binding(get: { profile.snapshot.backend }, set: { profile.backend = $0 })
    }
    private var localModelBinding: Binding<String> {
        Binding(get: { profile.snapshot.localModel }, set: { profile.localModel = $0 })
    }
    private var endpointModelBinding: Binding<String> {
        Binding(get: { profile.snapshot.endpointModel }, set: { profile.endpointModel = $0 })
    }
    private var templateBinding: Binding<LearningChatTemplate> {
        Binding(get: { profile.snapshot.template }, set: { profile.template = $0 })
    }
    private func refreshModels() { downloads?.refreshModelStates(); controller.refreshModels() }
}
