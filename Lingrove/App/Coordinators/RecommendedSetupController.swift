import Combine
import Foundation

/// WelcomeCoordinator owns this for the app lifetime, so closing the wizard does not abandon a
/// download. It borrows the app's downloader and runtime, and persists only a pending completion
/// choice. Learning profiles can retain missing filenames themselves until the shared scan finds
/// the downloaded file. No second model manager, credential store or native runtime is created.
@MainActor
final class RecommendedSetupController: ObservableObject {
    @Published private(set) var applied: Bool
    let settings: SuggestionSettingsModel
    let downloads: ModelDownloadManager
    let runtime: RuntimeBootstrapModel
    let speech: LearningSpeechSettings
    let foundation: FoundationModelAvailabilityService
    private let defaults: UserDefaults
    private let hardware: HardwareCapability
    private let downloadModel: (DownloadableRuntimeModel, LocalModelTask?) -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var pending: PendingCompletion? {
        didSet {
            defaults.set(pending.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.pendingKey)
        }
    }
    private static let pendingKey = "lingroveRecommendedSetup.pendingCompletion"
    private static let appliedKey = "lingroveRecommendedSetup.applied"

    /// A download receipt survives permission-related app restarts. The expected old selection
    /// prevents late completion from undoing a model the user selected in the meantime.
    private struct PendingCompletion: Codable {
        let filename: String
        let previous: String?
    }

    init(settings: SuggestionSettingsModel, downloads: ModelDownloadManager, runtime: RuntimeBootstrapModel,
         speech: LearningSpeechSettings, foundation: FoundationModelAvailabilityService,
         defaults: UserDefaults = .standard, hardware: HardwareCapability = HardwareCapabilityProbe.current(),
         downloadModel: ((DownloadableRuntimeModel, LocalModelTask?) -> Void)? = nil) {
        self.settings = settings; self.downloads = downloads; self.runtime = runtime
        self.speech = speech; self.foundation = foundation; self.defaults = defaults; self.hardware = hardware
        // The only injected effect is transfer dispatch. Tests can exercise real preferences,
        // persistence and discovery without downloading gigabytes or replacing the downloader.
        self.downloadModel = downloadModel ?? { downloads.download($0, for: $1) }
        applied = defaults.bool(forKey: Self.appliedKey)
        pending = defaults.data(forKey: Self.pendingKey).flatMap { try? JSONDecoder().decode(PendingCompletion.self, from: $0) }
        Publishers.MergeMany([
            downloads.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            runtime.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.languageLearning.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.languageLearning.expressionAssist.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.languageLearning.translation.changes,
            settings.languageLearning.explanation.changes,
            speech.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            foundation.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: RunLoop.main).sink { [weak self] in
            // @Published announces before assignment. Read committed values on the next run loop.
            self?.finishPendingCompletion()
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        finishPendingCompletion()
    }

    var plan: RecommendedSetupPolicy.Plan? {
        RecommendedSetupPolicy.plan(hardware: hardware, appleAvailable: foundation.isAvailable)
    }
    var needsCompletionSelection: Bool {
        pending != nil || (!settings.isPowerBasedModelSwitchingEnabled && settings.selectedEngine != .openAICompatible
            && runtime.selectedModelFilename == nil
            && (settings.selectedEngine != .appleIntelligence || !foundation.isAvailable))
    }
    var completionEngine: SuggestionEngineKind {
        if pending != nil { return .llamaOpenSource }
        return needsCompletionSelection ? plan?.completionEngine ?? settings.selectedEngine : settings.selectedEngine
    }
    var completionModel: DownloadableRuntimeModel? {
        guard completionEngine == .llamaOpenSource else { return nil }
        let filename = pending?.filename ?? (needsCompletionSelection ? plan?.completionModel?.filename : runtime.selectedModelFilename)
        return RuntimeModelCatalog.downloadableModels.first { $0.filename == filename }
    }
    func learningModel(_ role: LearningModelRole) -> DownloadableRuntimeModel? {
        let profile = role == .translation ? settings.languageLearning.translation : settings.languageLearning.explanation
        if RecommendedSetupPolicy.needsLearningSelection(profile) {
            return role == .translation ? plan?.translationModel : plan?.explanationModel
        }
        guard profile.snapshot.backend == .local else { return nil }
        return (LearningRuntimeCatalog.translationModels + LearningRuntimeCatalog.explanationModels)
            .first { $0.filename == profile.snapshot.localModel }
    }
    var models: [DownloadableRuntimeModel] {
        var seen = Set<String>()
        return [completionModel, learningModel(.translation), learningModel(.explanation)]
            .compactMap { $0 }.filter { seen.insert($0.id).inserted }
    }
    var downloadSize: String {
        let bytes = RecommendedSetupPolicy.downloadBytes(models.filter { !downloads.isModelInstalled($0) })
        return "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    var isDownloading: Bool { models.contains { downloads.state(for: $0).isDownloading } }
    var usesEndpoint: Bool {
        settings.selectedEngine == .openAICompatible
            || settings.languageLearning.translation.snapshot.backend == .endpoint
            || settings.languageLearning.explanation.snapshot.backend == .endpoint
            || speech.selectedProvider == .endpoint
    }
    var hasMissingDownloads: Bool { models.contains { !downloads.isModelInstalled($0) } }
    var pendingCompletionFilename: String? { pending?.filename }
    var needsApplication: Bool {
        !applied || (pending == nil && needsCompletionSelection)
            || RecommendedSetupPolicy.needsLearningSelection(settings.languageLearning.translation)
            || RecommendedSetupPolicy.needsLearningSelection(settings.languageLearning.explanation)
            || !settings.isGloballyEnabled || !settings.isCompletionEnabled || settings.isTemporarilyPaused
            || !settings.languageLearning.translationEnabled || !settings.languageLearning.sentencePreviewEnabled
            || !settings.languageLearning.selectionTranslationEnabled || !settings.languageLearning.selectionIconEnabled
            || !settings.languageLearning.expressionAssist.enabled
    }

    func apply() {
        guard let plan else { return }
        let completion = completionModel
        if needsCompletionSelection, pending == nil {
            settings.selectEngine(plan.completionEngine)
            if let completion {
                pending = PendingCompletion(filename: completion.filename, previous: runtime.selectedModelFilename)
            }
        }
        for (role, model) in [(LearningModelRole.translation, plan.translationModel), (.explanation, plan.explanationModel)] {
            let profile = role == .translation ? settings.languageLearning.translation : settings.languageLearning.explanation
            if RecommendedSetupPolicy.needsLearningSelection(profile) {
                profile.localModel = model.filename
                profile.template = .automatic
            }
        }
        RecommendedSetupPolicy.enableFeatures(settings)
        applied = true
        defaults.set(true, forKey: Self.appliedKey)
        if let completion { downloadModel(completion, .completion) }
        if let model = learningModel(.translation) { downloadModel(model, .translation) }
        if let model = learningModel(.explanation) { downloadModel(model, .explanation) }
        runtime.refreshAvailableModels()
        finishPendingCompletion()
    }

    func pauseDownloads() {
        for model in models where downloads.state(for: model).isDownloading { downloads.pause(model) }
    }

    func retryDownloads() {
        for model in models where !downloads.isModelInstalled(model) { downloadModel(model, nil) }
    }

    /// Switching to manual configuration explicitly ends the recommendation's selection lease;
    /// existing transfers remain visible and manageable in the ordinary model forms.
    func useManualConfiguration() { pending = nil }

    private func finishPendingCompletion() {
        guard let pending else { return }
        guard RecommendedSetupPolicy.canFinishCompletion(expected: pending.previous, current: runtime.selectedModelFilename,
            target: pending.filename, engine: settings.selectedEngine, powerSwitching: settings.isPowerBasedModelSwitchingEnabled) else {
            self.pending = nil
            return
        }
        guard runtime.availableModels.contains(where: { $0.filename == pending.filename }) else { return }
        // Persist the choice synchronously, without loading weights merely to paint setup status.
        // The existing runtime lifecycle loads it on the next eligible request.
        runtime.selectModelWithoutLoading(pending.filename)
        self.pending = nil
    }
}
