import Foundation

public struct SchedulerSettingsConfig: Equatable {
    public let algorithm: String
    public let desiredRetention: Double
    public let learningStepsMinutes: [Int]
    public let relearningStepsMinutes: [Int]
    public let maximumIntervalDays: Int
    public let enableFuzz: Bool

    public var learningStepsMinutesJson: String {
        encodeSchedulerStepListJson(values: self.learningStepsMinutes)
    }

    public var relearningStepsMinutesJson: String {
        encodeSchedulerStepListJson(values: self.relearningStepsMinutes)
    }

    public init(algorithm: String, desiredRetention: Double, learningStepsMinutes: [Int], relearningStepsMinutes: [Int], maximumIntervalDays: Int, enableFuzz: Bool) {
        self.algorithm = algorithm
        self.desiredRetention = desiredRetention
        self.learningStepsMinutes = learningStepsMinutes
        self.relearningStepsMinutes = relearningStepsMinutes
        self.maximumIntervalDays = maximumIntervalDays
        self.enableFuzz = enableFuzz
    }
}

public struct SchedulerSettingsDraft: Equatable {
    public var desiredRetentionText: String
    public var learningStepsText: String
    public var relearningStepsText: String
    public var maximumIntervalDaysText: String
    public var enableFuzz: Bool

    public init(desiredRetentionText: String, learningStepsText: String, relearningStepsText: String, maximumIntervalDaysText: String, enableFuzz: Bool) {
        self.desiredRetentionText = desiredRetentionText
        self.learningStepsText = learningStepsText
        self.relearningStepsText = relearningStepsText
        self.maximumIntervalDaysText = maximumIntervalDaysText
        self.enableFuzz = enableFuzz
    }
}

public let defaultSchedulerSettingsConfig: SchedulerSettingsConfig = SchedulerSettingsConfig(
    algorithm: "fsrs-6",
    desiredRetention: 0.90,
    learningStepsMinutes: [1, 10],
    relearningStepsMinutes: [10],
    maximumIntervalDays: 36_500,
    enableFuzz: true
)

public func makeSchedulerSettingsDraft(settings: WorkspaceSchedulerSettings) -> SchedulerSettingsDraft {
    makeSchedulerSettingsDraft(
        config: SchedulerSettingsConfig(
            algorithm: settings.algorithm,
            desiredRetention: settings.desiredRetention,
            learningStepsMinutes: settings.learningStepsMinutes,
            relearningStepsMinutes: settings.relearningStepsMinutes,
            maximumIntervalDays: settings.maximumIntervalDays,
            enableFuzz: settings.enableFuzz
        )
    )
}

public func makeDefaultSchedulerSettingsDraft() -> SchedulerSettingsDraft {
    makeSchedulerSettingsDraft(config: defaultSchedulerSettingsConfig)
}

public func formatSchedulerStepList(values: [Int]) -> String {
    values.map(String.init).joined(separator: ", ")
}

public func formatSchedulerRetentionValue(value: Double) -> String {
    String(format: "%.2f", value)
}

public func parseSchedulerDesiredRetention(text: String) throws -> Double {
    let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")

    guard let value = Double(normalizedText) else {
        throw LocalStoreError.validation("Desired retention must be a decimal number")
    }

    return value
}

public func parseSchedulerPositiveInteger(text: String, fieldName: String) throws -> Int {
    let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(normalizedText), value > 0 else {
        throw LocalStoreError.validation("\(fieldName) must be a positive integer")
    }

    return value
}

public func parseSchedulerStepList(text: String, fieldName: String) throws -> [Int] {
    let parts = text
        .split(separator: ",")
        .map { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { value in
            value.isEmpty == false
        }

    if parts.isEmpty {
        throw LocalStoreError.validation("\(fieldName) must not be empty")
    }

    return try parts.map { value in
        guard let step = Int(value) else {
            throw LocalStoreError.validation("\(fieldName) must contain integers")
        }

        return step
    }
}

private func makeSchedulerSettingsDraft(config: SchedulerSettingsConfig) -> SchedulerSettingsDraft {
    SchedulerSettingsDraft(
        desiredRetentionText: formatSchedulerRetentionValue(value: config.desiredRetention),
        learningStepsText: formatSchedulerStepList(values: config.learningStepsMinutes),
        relearningStepsText: formatSchedulerStepList(values: config.relearningStepsMinutes),
        maximumIntervalDaysText: String(config.maximumIntervalDays),
        enableFuzz: config.enableFuzz
    )
}

private func encodeSchedulerStepListJson(values: [Int]) -> String {
    "[" + values.map(String.init).joined(separator: ",") + "]"
}
