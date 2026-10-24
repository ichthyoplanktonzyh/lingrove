import Foundation

/// App-owned expression generator. It borrows the existing explanation controller and its loaded
/// runtime, but owns its own prompt/output contract and telemetry task identity. No editor handles
/// or automatic translation state enter this boundary.
@MainActor
final class ExpressionAssistService: ExpressionAssistGenerating {
    private let model: LearningModelController
    private let telemetry: LearningRequestTelemetry

    init(model: LearningModelController, telemetry: LearningRequestTelemetry) {
        self.model = model
        self.telemetry = telemetry
    }

    func generate(_ request: ExpressionAssistRequest, requestID: String) async throws -> ExpressionAssistResult {
        try Task.checkCancellation()
        let lease = model.reserveInstructionRequest()
        let profile = model.profile.snapshot
        return try await LearningRequestTrace.$requestID.withValue(requestID) {
            try await telemetry.perform(source: .expressionAssist, profile: profile) {
                try await self.model.validateGeneralInstructionModel()
                try self.model.validateInstructionRequest(lease)
                try Task.checkCancellation()
                guard self.model.profile.snapshot == profile else { throw CancellationError() }
                let output = min(profile.maximumOutputTokens ?? 768, 1_536)
                let prompt = try ExpressionAssistPrompt.render(request, total: profile.contextWindowTokens, output: output)
                var bytes = 0
                let raw = try await self.model.generate(prompt: prompt, maxTokens: output) { delta in
                    try self.model.validateInstructionRequest(lease)
                    try Task.checkCancellation()
                    guard self.model.profile.snapshot == profile else { throw CancellationError() }
                    bytes += delta.utf8.count
                    guard bytes <= 12_000 else { throw VocabularyError.invalidContent }
                }
                try Task.checkCancellation()
                try self.model.validateInstructionRequest(lease)
                guard self.model.profile.snapshot == profile else { throw CancellationError() }
                let result = try ExpressionAssistPrompt.parse(raw, request: request)
                LearningRequestTrace.measurement?.usable()
                return result
            }
        }
    }

    func recordDisplay(requestID: String) { telemetry.recordDisplay(source: .expressionAssist, requestID: requestID) }
}
