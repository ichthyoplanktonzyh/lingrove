import SwiftUI

/// The final page observes existing task settings, file discovery and permissions. It reports
/// configuration rather than warming models or probing endpoints just to paint a success badge.
/// WelcomeCoordinator supplies the app-owned objects and routes row clicks to the real settings.
struct WelcomeReadinessView: View {
    @ObservedObject var settings: SuggestionSettingsModel
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var runtime: RuntimeBootstrapModel
    @ObservedObject var foundation: FoundationModelAvailabilityService
    @ObservedObject var connection: OpenAICompatibleConnectionModel
    @ObservedObject var downloads: ModelDownloadManager
    @ObservedObject var translation: LearningModelSettings
    @ObservedObject var explanation: LearningModelSettings
    @ObservedObject var speech: LearningSpeechSettings
    @ObservedObject var translationController: LearningModelController
    @ObservedObject var explanationController: LearningModelController
    let speechController: LearningSpeechController
    let pendingCompletionModel: String?
    let open: (SettingsItem) -> Void

    var body: some View {
        VStack(spacing: 10) {
            row(.completion, status: completionStatus, detail: completionDetail, item: .engine)
            learningRow(translation, controller: translationController, task: .translation)
            learningRow(explanation, controller: explanationController, task: .explanation)
            row(.speech, status: speechController.configurationError == nil ? .configured : .needsConfiguration,
                detail: speechController.configurationError ?? speech.selectedProvider.label, item: .speechProvider)
            if !permissions.requiredPermissionsGranted {
                Button { open(.accessibility) } label: {
                    Label(String(localized: "Text access and global shortcuts need permissions.", table: "Learning"),
                        systemImage: "lock.shield")
                }
            }
            if !permissions.screenRecordingGranted {
                Button { open(.screenRecording) } label: {
                    Label(String(localized: "Screen OCR needs Screen Recording permission.", table: "Learning"),
                        systemImage: "text.viewfinder")
                }
            }
        }.accessibilityIdentifier("welcomeReadiness")
    }

    private func learningRow(_ profile: LearningModelSettings, controller: LearningModelController,
                             task: SettingsEngineTask) -> some View {
        let snapshot = profile.snapshot
        let model = (snapshot.backend == .local ? snapshot.localModel : snapshot.endpointModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valid: Bool
        if snapshot.backend == .local {
            valid = controller.availableModels.contains { $0.filename == model }
                && (task != .explanation || profile.generalInstructionsAvailable == true)
        } else {
            valid = (try? OpenAICompatibleEndpointConfiguration(baseURLString: snapshot.baseURL,
                modelName: model, apiMode: .chatCompletions)) != nil && controller.endpointConnection.state.failureDetail == nil
        }
        let catalog = task == .translation ? LearningRuntimeCatalog.translationModels : LearningRuntimeCatalog.explanationModels
        let downloading = catalog.first { $0.filename == model }
            .map { downloads.state(for: $0).isDownloading } ?? false
        return row(task, status: OnboardingSetupPolicy.modelStatus(selected: !model.isEmpty,
            available: valid, downloading: downloading),
            detail: snapshot.backend == .local ? LocalModelCatalog.displayName(for: model) : model,
            item: task == .translation ? .translationModel : .explanationModel)
    }

    private var completionStatus: OnboardingSetupPolicy.ModelStatus {
        switch settings.selectedEngine {
        case .appleIntelligence: foundation.isAvailable ? .configured : .unavailable
        case .llamaOpenSource:
            OnboardingSetupPolicy.modelStatus(selected: completionFilename != nil,
                available: runtime.availableModels.contains { $0.filename == completionFilename }
                    && runtime.state.failureDetail == nil,
                downloading: downloads.models.contains {
                    $0.filename == completionFilename && downloads.state(for: $0).isDownloading
                })
        case .openAICompatible:
            OnboardingSetupPolicy.modelStatus(
                selected: !settings.openAICompatibleModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                available: (try? settings.openAICompatibleConfiguration) != nil && connection.state.failureDetail == nil)
        }
    }
    private var completionFilename: String? { pendingCompletionModel ?? runtime.selectedModelFilename }
    private var completionDetail: String {
        switch settings.selectedEngine {
        case .appleIntelligence: settings.selectedEngine.displayLabel
        case .llamaOpenSource: completionFilename.map(LocalModelCatalog.displayName(for:)) ?? ""
        case .openAICompatible: settings.openAICompatibleModelName
        }
    }

    private func row(_ task: SettingsEngineTask, status: OnboardingSetupPolicy.ModelStatus,
                     detail: String, item: SettingsItem) -> some View {
        Button { open(item) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.label).font(.headline)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Text(status.label).font(.caption).foregroundStyle(status == .configured ? .green : .secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(14).contentShape(Rectangle()).onboardingCard(cornerRadius: 12)
        }.buttonStyle(.plain)
    }
}

private extension OnboardingSetupPolicy.ModelStatus {
    var label: String {
        switch self {
        case .needsConfiguration: String(localized: "No model configured", table: "Learning")
        case .downloading: String(localized: "Downloading your model…")
        case .configured: String(localized: "Configured", table: "Learning")
        case .unavailable: String(localized: "Needs attention", table: "Learning")
        }
    }
}
