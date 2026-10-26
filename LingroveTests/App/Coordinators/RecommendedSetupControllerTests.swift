import Foundation
import Testing
@testable import Lingrove

@Suite(.serialized)
@MainActor
struct RecommendedSetupControllerTests {
    @Test func openingSetupIsInertAndApplyingDispatchesOneDownloadPerTask() throws {
        let fixture = try RecommendedSetupFixture()
        defer { fixture.cleanup() }
        #expect(fixture.transfers.isEmpty)
        #expect(!fixture.settings.languageLearning.expressionAssist.enabled)
        fixture.setup.apply()
        #expect(fixture.transfers.count == 3)
        #expect(Set(fixture.transfers).count == 3)
        #expect(fixture.setup.pendingCompletionFilename != nil)
        #expect(fixture.settings.languageLearning.explanation.localModel == "Qwen3.5-4B-Q4_K_M.gguf")
        #expect(fixture.settings.languageLearning.expressionAssist.enabled)
        #expect(fixture.speech.selectedProvider == .system)
    }

    @Test func pendingSelectionSurvivesReopeningAndManualConfigurationReleasesIt() throws {
        let fixture = try RecommendedSetupFixture()
        defer { fixture.cleanup() }
        fixture.setup.apply()
        let filename = try #require(fixture.setup.pendingCompletionFilename)
        let restored = fixture.makeController()
        #expect(restored.pendingCompletionFilename == filename)
        #expect(fixture.transfers.count == 3) // Reconstruction does not restart transfers.
        restored.useManualConfiguration()
        #expect(fixture.makeController().pendingCompletionFilename == nil)
    }

    @Test func completedDownloadSelectsTheModelWithoutLoadingWeights() async throws {
        let fixture = try RecommendedSetupFixture()
        defer { fixture.cleanup() }
        fixture.setup.apply()
        let filename = try #require(fixture.setup.pendingCompletionFilename)
        try Data("discovery fixture, never loaded".utf8).write(to: fixture.directory.appendingPathComponent(filename))
        fixture.runtime.refreshAvailableModels()
        for _ in 0..<40 where fixture.setup.pendingCompletionFilename != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.setup.pendingCompletionFilename == nil)
        #expect(fixture.runtime.selectedModelFilename == filename)
        #expect(fixture.defaults.string(forKey: "lingroveSelectedModelFilename") == filename)
    }

    @Test func configuredEndpointsAndLanguagePreferencesArePreserved() throws {
        let fixture = try RecommendedSetupFixture()
        defer { fixture.cleanup() }
        fixture.settings.selectEngine(.openAICompatible)
        fixture.settings.languageLearning.translation.backend = .endpoint
        fixture.settings.languageLearning.translation.endpointModel = "existing-translation"
        fixture.settings.languageLearning.explanation.backend = .endpoint
        fixture.settings.languageLearning.explanation.endpointModel = "existing-explanation"
        fixture.settings.languageLearning.targetLanguage = .japanese
        fixture.setup.apply()
        #expect(fixture.transfers.isEmpty)
        #expect(fixture.setup.usesEndpoint)
        #expect(fixture.settings.selectedEngine == .openAICompatible)
        #expect(fixture.settings.languageLearning.translation.endpointModel == "existing-translation")
        #expect(fixture.settings.languageLearning.explanation.endpointModel == "existing-explanation")
        #expect(fixture.settings.languageLearning.targetLanguage == .japanese)
    }

    @Test func retryingDownloadsDoesNotReenableAFeatureTheUserTurnedOff() throws {
        let fixture = try RecommendedSetupFixture()
        defer { fixture.cleanup() }
        fixture.setup.apply()
        fixture.settings.languageLearning.expressionAssist.enabled = false
        fixture.setup.retryDownloads()
        #expect(!fixture.settings.languageLearning.expressionAssist.enabled)
        #expect(fixture.transfers.count == 6)
    }
}

/// Isolated stores and an empty discovery directory exercise the app-owned setup boundary. The
/// transfer callback records intent; no test calls a network, loads a model, or edits real defaults.
@MainActor
final class RecommendedSetupFixture {
    let suite = "lingrove.test.setup.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let settings: SuggestionSettingsModel
    let speech: LearningSpeechSettings
    let runtime: RuntimeBootstrapModel
    let downloads: ModelDownloadManager
    let foundation = FoundationModelAvailabilityService(provider: SetupUnavailableFoundation())
    var transfers: [String] = []
    lazy var setup = makeController()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        speech = LearningSpeechSettings(defaults: defaults)
        let assignments = LocalModelTaskAssignments(defaults: defaults)
        let manager = LlamaRuntimeManager(configuration: .init(runtimeDirectoryPath: directory.path,
            preferredModelNames: [], contextWindowTokens: 512, batchSize: 128, gpuLayerCount: 0),
            runtimeLocator: BundledRuntimeLocator(), modelTaskAssignments: assignments)
        runtime = RuntimeBootstrapModel(runtimeManager: manager, userDefaults: defaults)
        runtime.shouldLoadSelectedModel = { false }
        downloads = ModelDownloadManager(runtimeDirectoryURL: directory, assetCatalog: [], taskAssignments: assignments)
    }
    func makeController() -> RecommendedSetupController {
        RecommendedSetupController(settings: settings, downloads: downloads, runtime: runtime, speech: speech,
            foundation: foundation, defaults: defaults, hardware: .init(physicalMemoryBytes: 16 * 1_073_741_824),
            downloadModel: { [weak self] model, _ in self?.transfers.append(model.filename) })
    }
    func cleanup() {
        runtime.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private struct SetupUnavailableFoundation: FoundationModelAvailabilityProviding {
    let currentState: FoundationModelAvailabilityState = .unavailable("Test fixture")
    func refresh() -> FoundationModelAvailabilityState { currentState }
    func observe(onChange: @escaping @MainActor (FoundationModelAvailabilityState) -> Void) -> Task<Void, Never>? { nil }
}
