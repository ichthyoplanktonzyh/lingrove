import LingroveNotebook
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
                let measurement = LearningRequestTrace.measurement
                var bytes = 0
                let raw = try await self.model.generate(prompt: prompt, maxTokens: output) { delta in
                    try self.model.validateInstructionRequest(lease)
                    try Task.checkCancellation()
                    guard self.model.profile.snapshot == profile else { throw CancellationError() }
                    bytes += delta.utf8.count
                    guard bytes <= 12_000 else {
                        measurement?.record("output_stream_rejected", details: [
                            "reason": "output_too_large", "stream_bytes": String(bytes)
                        ])
                        throw VocabularyError.invalidContent
                    }
                }
                try Task.checkCancellation()
                try self.model.validateInstructionRequest(lease)
                guard self.model.profile.snapshot == profile else { throw CancellationError() }
                // The callback and parser consume the same generation through different paths.
                // Compare bytes to the existing debug capture without emitting another copy.
                var details = ["stream_bytes": String(bytes), "parser_bytes": String(raw.utf8.count)]
                if LingroveDebugOptions.isEnabled, let measurement {
                    details["matches_debug_output"] = String(raw.utf8.elementsEqual(measurement.rawOutput.utf8))
                }
                measurement?.record("output_received", details: details)
                do {
                    let result = try ExpressionAssistPrompt.parse(raw, request: request)
                    measurement?.usable()
                    return result
                } catch let rejection as ExpressionAssistPrompt.Rejection {
                    var details = ["reason": rejection.reason]
                    details["coding_path"] = rejection.codingPath
                    details["candidate_index"] = rejection.candidateIndex.map { String($0) }
                    measurement?.record("output_rejected", details: details)
                    throw rejection
                }
            }
        }
    }

    func recordDisplay(requestID: String) { telemetry.recordDisplay(source: .expressionAssist, requestID: requestID) }
}
