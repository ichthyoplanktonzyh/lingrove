import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Speech shares the task page's current-configuration, model-manager and advanced hierarchy.
/// The app owns speech services and durable preferences; this view owns audition language,
/// credential drafts and confirmation state. Opening configuration never starts generation.
struct SpeechConfigurationView: View {
    @ObservedObject var speech: LearningSpeechController
    @ObservedObject var navigation: SettingsNavigationModel
    @State private var voiceLanguage: LearningLanguage = .english
    @State private var testOwnerID = UUID()
    @State var keyDraft = ""
    @State var savedKey = ""
    @State var credentialError: String?
    @State var pendingDeletion: RuntimeModelOption?

    private var testTarget: SpeechTarget { .init(ownerID: testOwnerID, itemID: "settings.testVoice.\(voiceLanguage.rawValue)") }
    private var testRequest: SpeechRequest {
        .init(target: testTarget, text: testPhrase, language: voiceLanguage, languageMode: .fixed)
    }
    private var voiceChoices: [SpeechVoice] { speech.voices(for: voiceLanguage) }

    var body: some View {
        let identity = speech.settings.parameterIdentity
        return SettingsPaneScaffold {
            Section(String(localized: "Current configuration", table: "Learning")) {
                Picker(selection: Binding(get: { speech.settings.selectedProvider }, set: speech.settings.selectProvider)) {
                    ForEach(LearningSpeechProviderKind.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingsRowLabel(title: String(localized: "Run using", table: "Learning"),
                        description: String(localized: "Choose system voices, a local speech model, or your TTS endpoint.",
                            table: "Learning"), systemImage: "cpu")
                }
                .pickerStyle(.menu).settingsItem(.speechProvider)
                if let item = navigation.revealedItem, let requested = requestedProvider(for: item) {
                    Button(String(localized: "Configure selected setting", table: "Learning")) {
                        speech.settings.selectProvider(requested)
                        navigation.refreshReveal()
                    }.settingsItem(item)
                }
                Button(String(localized: "Manage models", table: "Learning")) { navigation.openModelManager(.speech) }
            }
            switch speech.settings.selectedProvider {
            case .system: systemSection
            case .local:
                localSections
                Section(String(localized: "Voice", table: "Learning")) {
                    assetRow(title: String(localized: "Reference voice (optional)", table: "Learning"),
                        path: speech.settings.referenceAudioPath, audio: true, set: speech.settings.setReferenceAudioPath)
                    Text(verbatim: "WAV / MP3 · ≤30 s · ≤10 MB").font(.caption).foregroundStyle(.secondary)
                }
            case .endpoint:
                endpointModelSection
                endpointVoiceSection
                endpointConnectionSection
            }
            if speech.settings.selectedProvider != .system {
                Section(String(localized: "Expression style", table: "Learning")) {
                    LabeledContent(String(localized: "Style instructions", table: "Learning"), value:
                        speech.settings.selectedProvider == .local
                        ? String(localized: "Not supported by Base models", table: "Learning")
                        : String(localized: "Not available through this interface", table: "Learning"))
                }
            }
            auditionSection
            if speech.settings.selectedProvider == .local {
                SettingsAdvancedSections(isExpanded: navigation.advancedBinding(for: .speech)) {
                    decoderSection
                    ModelSamplingSection(overrides: Binding(get: { speech.settings.generationProfile.sampling }, set: {
                        speech.settings.setSamplingOverrides($0, expectedIdentity: identity)
                    }), recommended: .speech, local: true, speech: true, item: .speechSampling)
                    .id(identity)
                }
            }
        }
        .onAppear { refreshProvider() }
        .onChange(of: speech.settings.selectedProvider) { _, _ in refreshProvider() }
        .onChange(of: voiceLanguage) { _, _ in speech.stop(ownerID: testOwnerID) }
        .onDisappear { speech.stop(ownerID: testOwnerID) }
        .sheet(isPresented: navigation.modelManagerBinding(for: .speech)) {
            SettingsModelManagementSheet(task: .speech) { modelManagementSections }
            .onAppear(perform: refreshLocalModels)
            .alert(String(localized: "Delete model?", table: "Learning"),
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                presenting: pendingDeletion) { model in
                Button(String(localized: "Delete", table: "Learning")) {
                    speech.modelDownloads.deleteModel(filename: model.filename)
                    refreshLocalModels()
                    pendingDeletion = nil
                }
                Button(String(localized: "Cancel", table: "Learning"), role: .cancel) { pendingDeletion = nil }
            } message: { model in Text(String(localized: "Remove \(model.displayName) from this Mac?", table: "Learning")) }
        }
    }

    /// Model files are configured independently of their lazy runtime. A changed selection
    /// must not inherit the previous model's Ready badge while its weights are still resident.
    var runtimeStatus: String {
        let filename = URL(fileURLWithPath: speech.settings.localModelPath).lastPathComponent
        if !speech.settings.localModelPath.isEmpty, !LocalModelTaskPolicy.supports(filename, task: .speech) {
            return String(localized: "This model is not compatible with this task. Choose another model.", table: "Learning")
        }
        if let error = speech.configurationError { return error }
        let runtime = speech.telemetry.runtime
        if runtime.modelName != URL(fileURLWithPath: speech.settings.localModelPath).lastPathComponent
            || runtime.phase == .unloaded {
            return String(localized: "Configured · loads on first use", table: "Learning")
        }
        return runtime.phase.label
    }

    var voiceLanguagePicker: some View {
        Picker(selection: $voiceLanguage) {
            ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
        } label: {
            SettingsRowLabel(title: String(localized: "Audition language", table: "Learning"),
                description: String(localized: "Choose the language to use when testing speech.", table: "Learning"),
                systemImage: "character.bubble")
        }.pickerStyle(.menu).settingsItem(.speechLanguage)
    }

    private var systemSection: some View {
        Section(String(localized: "Voice", table: "Learning")) {
            voiceLanguagePicker
            Picker(selection: Binding(get: {
                speech.settings.voiceID(for: voiceLanguage).flatMap { saved in
                    voiceChoices.contains(where: { $0.id == saved }) ? saved : nil
                } ?? voiceChoices.first(where: { !$0.isNovelty })?.id ?? ""
            }, set: { speech.settings.setVoiceID($0.isEmpty ? nil : $0, for: voiceLanguage) })) {
                ForEach(voiceChoices) { Text($0.name).tag($0.id) }
            } label: {
                SettingsRowLabel(title: String(localized: "System voice", table: "Learning"),
                    description: String(localized: "Choose an installed system voice for the selected language.", table: "Learning"),
                    systemImage: "waveform")
            }
            .pickerStyle(.menu).disabled(voiceChoices.isEmpty).settingsItem(.speechVoice)
            if voiceChoices.isEmpty {
                Text(speech.voiceCatalogError ?? String(
                    localized: "No compatible system voice is installed for this language.", table: "Learning"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let saved = speech.settings.voiceID(for: voiceLanguage), !voiceChoices.contains(where: { $0.id == saved }) {
                Text(String(localized: "The saved voice is unavailable. Lingrove will use an available voice until you choose another.",
                    table: "Learning")).font(.caption).foregroundStyle(.secondary)
            }
            Text(String(localized: "System speech plays locally with installed macOS voices.", table: "Learning"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func assetRow(title: String, path: String, audio: Bool, set: @escaping (String) -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(path.isEmpty ? String(localized: "Not selected", table: "Learning")
                    : SpeechModelCatalog.displayName(for: URL(fileURLWithPath: path).lastPathComponent))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing).help(path)
                Button(String(localized: "Choose…", table: "Learning")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = audio
                        ? [.wav, .mp3] : [UTType(filenameExtension: "gguf") ?? .data]
                    if panel.runModal() == .OK, let url = panel.url { set(url.path) }
                }
                if !path.isEmpty { Button(String(localized: "Clear")) { set("") } }
            }
        } label: { SettingsRowLabel(title: title, description: "", systemImage: audio ? "waveform" : "shippingbox") }
        .accessibilityElement(children: .contain)
    }

    private var auditionSection: some View {
        Section(String(localized: "Test voice", table: "Learning")) {
            if speech.settings.selectedProvider == .local { voiceLanguagePicker }
            if speech.settings.selectedProvider == .local, LocalSpeechLanguage.code(for: voiceLanguage) == nil {
                Text(SpeechError.unsupportedLanguage.localizedDescription).font(.caption).foregroundStyle(.secondary)
            }
            Text(testPhrase).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 8) {
                Button(action: testVoice) {
                    Label(speech.isPlaying(testTarget)
                        ? String(localized: "Stop voice test", table: "Learning") : String(localized: "Test voice", table: "Learning"),
                        systemImage: speech.isPlaying(testTarget) ? "stop.fill" : "speaker.wave.2")
                }.buttonStyle(.bordered)
                if speech.isPreparing(testTarget) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Generating speech…", table: "Learning")).font(.caption)
                }
            }
            if let error = speech.error(for: testTarget) { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func requestedProvider(for item: SettingsItem) -> LearningSpeechProviderKind? {
        switch item {
        case .speechEndpoint, .speechEndpointModel, .speechEndpointVoice:
            speech.settings.selectedProvider != .endpoint ? .endpoint : nil
        case .speechModel, .speechDecoder, .speechSampling:
            speech.settings.selectedProvider != .local ? .local : nil
        case .speechVoice:
            speech.settings.selectedProvider != .system ? .system : nil
        default: nil
        }
    }

    func testVoice() {
        if speech.isPlaying(testTarget) { speech.stop(target: testTarget); return }
        do {
            if speech.settings.selectedProvider == .endpoint { try saveKeyIfNeeded() }
            credentialError = nil
            speech.toggle(testRequest)
        } catch { credentialError = error.localizedDescription }
    }

    func saveKeyIfNeeded() throws {
        guard keyDraft != savedKey else { return }
        try speech.settings.saveEndpointAPIKey(keyDraft.isEmpty ? nil : keyDraft)
        savedKey = keyDraft
        credentialError = nil
    }

    private func refreshProvider() {
        if speech.settings.selectedProvider == .system { speech.refreshVoices() }
        if speech.settings.selectedProvider == .local { refreshLocalModels() }
        if speech.settings.selectedProvider == .endpoint {
            do {
                keyDraft = try speech.settings.endpointAPIKey() ?? ""
                savedKey = keyDraft
                credentialError = nil
            } catch { credentialError = error.localizedDescription }
        }
    }

    private var testPhrase: String {
        switch voiceLanguage {
        case .english: "Hello. This is a voice preview."
        case .spanish: "Hola. Esta es una prueba de voz."
        case .french: "Bonjour. Ceci est un essai vocal."
        case .german: "Hallo. Dies ist eine Sprachprobe."
        case .italian: "Ciao. Questa è una prova vocale."
        case .portuguese: "Olá. Esta é uma amostra de voz."
        case .dutch: "Hallo. Dit is een stemtest."
        case .russian: "Здравствуйте. Это проверка голоса."
        case .chinese: "你好，这是语音试听。"
        case .traditionalChinese: "你好，這是語音試聽。"
        case .japanese: "こんにちは。音声の試聴です。"
        case .korean: "안녕하세요. 음성 미리 듣기입니다."
        case .hindi: "नमस्ते। यह आवाज़ का नमूना है।"
        case .arabic: "مرحبًا، هذه عينة صوتية."
        }
    }
}
