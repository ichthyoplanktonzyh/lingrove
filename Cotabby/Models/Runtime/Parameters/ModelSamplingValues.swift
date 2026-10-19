import Foundation

/// Fully resolved sampler values belong to one operation, not a model allocation. Services
/// choose defaults from their real adapter; the shared override policy clamps only user edits.
nonisolated struct ModelSamplingValues: Equatable, Sendable {
    let temperature: Double
    let topP: Double
    let topK: Int
    let repetitionPenalty: Double
    var seed: UInt32 = UInt32.max

    func applying(_ overrides: ModelSamplingOverrides) -> Self {
        let value = overrides.normalized
        return .init(temperature: value.temperature ?? temperature, topP: value.topP ?? topP,
            topK: value.topK ?? topK, repetitionPenalty: value.repetitionPenalty ?? repetitionPenalty,
            seed: value.seed(recommended: seed))
    }

    func customized(local: Bool) -> ModelSamplingOverrides {
        .init(temperature: temperature, topP: topP, topK: local ? topK : nil,
            repetitionPenalty: local ? repetitionPenalty : nil)
    }

    /// Mirrors the pinned helper's common sampler without overriding its active min-p stage.
    static let speech = Self(temperature: 0.8, topP: 0.95, topK: 40, repetitionPenalty: 1, seed: 42)
}
