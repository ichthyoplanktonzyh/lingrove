import Foundation

/// Optional request-level overrides shared by translation and local speech. Nil retains the
/// selected model adapter's recommendation; clamping is repeated at resolution, so decoded
/// preferences and UI edits cannot pass non-finite values or overflow native sampler arguments.
/// This value never belongs to a loaded-model identity and cannot trigger a weights reload.
nonisolated struct ModelSamplingOverrides: Codable, Equatable, Hashable, Sendable {
    enum SeedMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case recommended, random, fixed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recommended: String(localized: "Recommended", table: "Learning")
            case .random: String(localized: "Random", table: "Learning")
            case .fixed: String(localized: "Fixed", table: "Learning")
            }
        }
    }

    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var repetitionPenalty: Double?
    var seedMode: SeedMode = .recommended
    var fixedSeed: UInt32 = 42

    var isRecommended: Bool {
        temperature == nil && topP == nil && topK == nil && repetitionPenalty == nil && seedMode == .recommended
    }

    var normalized: Self {
        var value = self
        value.temperature = Self.bounded(temperature, in: 0...2)
        value.topP = Self.bounded(topP, in: 0.01...1)
        value.topK = topK.map { min(max($0, 1), 256) }
        value.repetitionPenalty = Self.bounded(repetitionPenalty, in: 1...2)
        value.fixedSeed = min(fixedSeed, UInt32.max - 1)
        return value
    }

    func seed(recommended: UInt32) -> UInt32 {
        switch seedMode {
        case .recommended: recommended
        case .random: UInt32.max
        case .fixed: normalized.fixedSeed
        }
    }

    /// Generic compatible endpoints only receive the sampling fields already supported by our
    /// transport. Dormant local-only preferences remain saved but do not invalidate HTTP work.
    var endpointOnly: Self {
        let value = normalized
        return .init(temperature: value.temperature, topP: value.topP)
    }

    private static func bounded(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
