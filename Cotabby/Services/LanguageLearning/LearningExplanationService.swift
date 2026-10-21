import Combine
import Foundation

/// The model collection owns this explicit-only task. It borrows one independent model controller
/// and the shared telemetry boundary, and caches a bounded number of complete results. Notebook
/// persistence is supplied by the composition root, keeping model work independent of storage/UI.
@MainActor
final class LearningExplanationService: LearningExplanationGenerating {
    let settings: LanguageLearningSettings
    let model: LearningModelController
    private let telemetry: LearningRequestTelemetry
    private struct Key: Hashable {
        let input: LearningExplanationInput
        let language: LearningLanguage
        let profile: LearningModelSnapshot
    }
    private var cache: [Key: LearningExplanationRecord] = [:]
    private var cacheOrder: [Key] = []
    var didExplain: ((LearningExplanationRecord) -> Void)?
    var configure: (() -> Void)?
    var loadPersisted: ((LearningExplanationInput, LearningLanguage) async -> LearningExplanationRecord?)?
    func loadSaved(for input: LearningExplanationInput) async -> LearningExplanationRecord? {
        let language = language
        let record = await loadPersisted?(input, language) ?? savedRecord(for: input)
        return self.language == language ? record : nil
    }
    var lookupSaved: ((LearningExplanationInput, LearningLanguage) -> LearningExplanationRecord?)?

    func savedRecord(for input: LearningExplanationInput) -> LearningExplanationRecord? { lookupSaved?(input, language) }

    init(settings: LanguageLearningSettings, model: LearningModelController, telemetry: LearningRequestTelemetry) {
        self.settings = settings; self.model = model; self.telemetry = telemetry
    }
    var changes: AnyPublisher<Void, Never> { settings.explanationChanges }
    var language: LearningLanguage { settings.resolvedExplanationLanguage }
    var isConfigured: Bool {
        let profile = model.profile.snapshot
        let name = profile.backend == .local ? profile.localModel : profile.endpointModel
        return !name.isEmpty && LearningExplanationPolicy.supportsGeneralInstructions(model: name, template: profile.template)
    }

    func cached(_ input: LearningExplanationInput) -> LearningExplanationRecord? {
        cache[Key(input: input, language: language, profile: model.profile.snapshot)]
    }

    func generate(_ input: LearningExplanationInput, requestID: String,
                  refresh: Bool = false) async throws -> LearningExplanationRecord {
        guard LearningExplanationPolicy.isValid(input) else { throw VocabularyError.invalidContent }
        let profile = model.profile.snapshot, language = language
        let key = Key(input: input, language: language, profile: profile)
        if !refresh {
            if let result = await loadSaved(for: input) ?? cache[key] {
                try Task.checkCancellation()
                guard model.profile.snapshot == profile, self.language == language else { throw CancellationError() }
                return result
            }
        }
        try Task.checkCancellation()
        guard model.profile.snapshot == profile, self.language == language else { throw CancellationError() }
        return try await LearningRequestTrace.$requestID.withValue(requestID) {
            try await telemetry.perform(source: .explanation, profile: profile) {
                guard self.isConfigured else {
                    throw LearningFailure.message(String(
                        localized: "Choose a general instruction model for AI explanation.", table: "Learning"))
                }
                try await self.model.validateGeneralInstructionModel()
                let output = profile.maximumOutputTokens ?? 1_024
                let prompt = try LearningExplanationPolicy.prompt(input, language: language,
                    total: profile.contextWindowTokens, output: output)
                @MainActor func validate() throws {
                    try Task.checkCancellation()
                    guard self.model.profile.snapshot == profile, self.language == language else { throw CancellationError() }
                }
                try validate()
                var bytes = 0
                let raw = try await self.model.generate(prompt: prompt, maxTokens: output) { delta in
                    try validate()
                    bytes += delta.utf8.count
                    guard bytes <= 24_000 else { throw VocabularyError.invalidContent }
                }
                try validate()
                let result = try LearningExplanationPolicy.parse(raw)
                LearningRequestTrace.measurement?.usable()
                let record = LearningExplanationRecord(id: UUID(), input: input, language: language, result: result,
                    model: profile.backend == .local ? profile.localModel : profile.endpointModel, createdAt: Date())
                if self.cache[key] == nil { self.cacheOrder.append(key) }
                self.cache[key] = record
                // Contexts dominate memory, so both entry count and retained UTF-8 bytes are bounded.
                while self.cacheOrder.count > 48 || self.cacheBytes > 4 * 1_024 * 1_024 {
                    self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
                }
                self.didExplain?(record)
                return record
            }
        }
    }
    private var cacheBytes: Int {
        cache.values.reduce(0) { $0 + $1.input.target.utf8.count + $1.input.context.utf8.count +
            $1.input.dictionaryForm.utf8.count + $1.result.meaning.utf8.count + $1.result.explanation.utf8.count }
    }
    func recordDisplay(requestID: String) { telemetry.recordDisplay(source: .explanation, requestID: requestID) }
}
