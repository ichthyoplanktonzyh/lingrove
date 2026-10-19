import Foundation

/// Request kind is independent of model/backend: one server can serve several tasks without
/// making their durations or quality counters comparable. Performance defaults to completion.
nonisolated enum ModelRequestSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case completion, translation, analysis, speech, ocr
    var id: String { rawValue }
    var label: String {
        switch self {
        case .completion: String(localized: "Autocomplete")
        case .translation: String(localized: "Translation", table: "Learning")
        case .analysis: String(localized: "Learning Analysis", table: "Learning")
        case .ocr: String(localized: "Screen OCR", table: "Learning")
        case .speech: String(localized: "TTS", table: "Learning")
        }
    }
}

/// Completed means the task returned a validated result, not that a human judged its quality.
/// In old completion records it also includes normalized/suppressed results, so it stays neutral.
nonisolated enum ModelRequestOutcome: String, Codable, Sendable {
    case completed, failed, cancelled
    var label: String {
        switch self {
        case .completed:
            String(localized: "Completed", table: "Learning")
        case .failed:
            String(localized: "Failed", table: "Learning")
        case .cancelled:
            String(localized: "Cancelled", table: "Learning")
        }
    }
}

/// Content-free persisted request record. Optional stage timings mean unobserved/not applicable;
/// zero is a measured duration. The decoder preserves literal pre-learning history without a reset.
nonisolated struct PerformanceMetricEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let modelName: String
    let latencyMs: Int
    let source: ModelRequestSource
    let outcome: ModelRequestOutcome
    let requestID: String?
    var modelLoadMs: Int?
    let firstOutputMs: Int?
    let usableResultMs: Int?
    var displayMs: Int?

    init(id: UUID = UUID(), timestamp: Date = Date(), modelName: String, latencyMs: Int,
         source: ModelRequestSource = .completion, outcome: ModelRequestOutcome = .completed,
         requestID: String? = nil, modelLoadMs: Int? = nil, firstOutputMs: Int? = nil,
         usableResultMs: Int? = nil, displayMs: Int? = nil) {
        self.id = id; self.timestamp = timestamp; self.modelName = modelName; self.latencyMs = latencyMs
        self.source = source; self.outcome = outcome; self.requestID = requestID
        self.modelLoadMs = modelLoadMs; self.firstOutputMs = firstOutputMs
        self.usableResultMs = usableResultMs; self.displayMs = displayMs
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, modelName, latencyMs, source, outcome, requestID
        case modelLoadMs, firstOutputMs, usableResultMs, displayMs
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id); timestamp = try container.decode(Date.self, forKey: .timestamp)
        modelName = try container.decode(String.self, forKey: .modelName); latencyMs = try container.decode(Int.self, forKey: .latencyMs)
        source = try container.decodeIfPresent(ModelRequestSource.self, forKey: .source) ?? .completion
        outcome = try container.decodeIfPresent(ModelRequestOutcome.self, forKey: .outcome) ?? .completed
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        modelLoadMs = try container.decodeIfPresent(Int.self, forKey: .modelLoadMs)
        firstOutputMs = try container.decodeIfPresent(Int.self, forKey: .firstOutputMs)
        usableResultMs = try container.decodeIfPresent(Int.self, forKey: .usableResultMs)
        displayMs = try container.decodeIfPresent(Int.self, forKey: .displayMs)
    }
}
