import Foundation

/// Translation owns only the quick expression task. The facade retains it for the app lifetime;
/// explanation settings/credentials never participate in its snapshot or cancel its result.
@MainActor
final class LearningTranslationService {
    let settings: SuggestionSettingsModel
    let model: LearningModelController
    private let telemetry: LearningRequestTelemetry
    init(settings: SuggestionSettingsModel, model: LearningModelController, telemetry: LearningRequestTelemetry) {
        self.settings = settings; self.model = model; self.telemetry = telemetry
    }

    func generate(source: String, task: LearningExpressionTask,
                  onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await generate(input: .init(source: source), task: task, onPartial: onPartial)
    }

    func generate(input: LearningTranslationInput, task: LearningExpressionTask,
                  onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await telemetry.perform(source: .translation, profile: model.profile.snapshot) {
            try await self.generateValidated(input: input, task: task, onPartial: onPartial)
        }
    }

    private func generateValidated(input: LearningTranslationInput, task: LearningExpressionTask,
                                   onPartial: (@MainActor (String) -> Void)?) async throws -> String {
        try Task.checkCancellation()
        let snapshot = settings.languageLearning.snapshot
        guard snapshot.translationEnabled, settings.isGloballyEnabled, !settings.isTemporarilyPaused else {
            throw CancellationError()
        }
        let sourceLanguage: LearningLanguage?
        switch task {
        case .translation(let language, let target):
            let allowed = input.origin == .reading
                ? settings.languageLearning.readingEnabled(input.readingSource) && settings.languageLearning.readingTargetLanguage == target
                : (language.map { snapshot.sourceLanguages.contains($0) } ?? false) && snapshot.targetLanguage == target
            guard allowed, language != target else {
                throw LearningFailure.message(String(localized: """
                The source language is not enabled or matches the target. Check the translation settings.
                """,
                    table: "Learning", comment: """
                    Error shown when the requested translation direction is not enabled or has identical source and target languages.
                    """))
            }
            sourceLanguage = language
        }
        let profile = model.profile.snapshot
        let readingTarget = settings.languageLearning.readingTargetLanguage
        func validateReading() throws {
            if input.origin == .reading {
                guard settings.languageLearning.readingEnabled(input.readingSource),
                      settings.languageLearning.readingTargetLanguage == readingTarget else { throw CancellationError() }
            }
        }
        func configurationIsCurrent() -> Bool {
            if input.origin == .reading {
                return settings.languageLearning.translationEnabled && model.profile.snapshot == profile
            }
            return settings.languageLearning.snapshot == snapshot
        }
        guard input.source.utf8.count <= ModelContextBudget.maximumTextBytes else { throw ModelContextBudget.oversizedTarget() }
        let output = try ModelContextBudget.translationOutputTokens(source: input.source, total: profile.contextWindowTokens)
        let request = try await model.translationPlan(
            input: input, sourceLanguage: sourceLanguage,
            targetLanguage: task.target, output: output)
        try Task.checkCancellation()
        try validateReading()
        guard model.profile.snapshot == profile, configurationIsCurrent() else { throw CancellationError() }
        var stream = LearningExpressionOutputPolicy.Stream()
        var lastPublication: TimeInterval?
        // First nonblank text is immediate. Later prefixes coalesce to at most 30 updates/second
        // without another timer or task; completion always publishes the final value to callers.
        let receive: (@MainActor (String) throws -> Void)?
        if let publish = onPartial {
            receive = { @MainActor delta in
                try Task.checkCancellation()
                try validateReading()
                guard configurationIsCurrent(), self.settings.isGloballyEnabled, !self.settings.isTemporarilyPaused else {
                    throw CancellationError()
                }
                guard let prefix = try stream.append(delta) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if lastPublication == nil || now - (lastPublication ?? now) >= 1.0 / 30 {
                    lastPublication = now
                    publish(prefix)
                }
            }
        } else { receive = nil }
        let raw = try await model.generate(
            prompt: request.prompt, maxTokens: output,
            userOnly: request.userOnly, sampling: request.sampling, onDelta: receive)
        try Task.checkCancellation()
        try validateReading()
        guard configurationIsCurrent(), settings.isGloballyEnabled, !settings.isTemporarilyPaused else {
            throw CancellationError()
        }
        let result = try LearningExpressionOutputPolicy.validatedText(raw)
        LearningRequestTrace.measurement?.usable()
        return result
    }
}
