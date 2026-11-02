import Foundation

/**
 FSRS-facing Swift types mirror the backend scheduler contract plus the web and
 Android transport/data types. The iOS scheduler implementation itself lives in
 `FsrsScheduler.swift`.

 Keep these FSRS-facing types aligned with:
 - apps/backend/src/scheduling/index.ts
 - apps/backend/src/cards/index.ts
 - apps/backend/src/scheduling/workspaceSettings.ts
 - apps/web/src/types.ts
 - apps/android/data/local/src/main/java/com/flashcardsopensourceapp/data/local/model/scheduling/SchedulingModels.kt
 - docs/fsrs-scheduling-logic.md
 */

// Keep in sync with apps/backend/src/scheduling/index.ts::FsrsCardState, apps/web/src/types.ts::FsrsCardState, and apps/android/data/local/src/main/java/com/flashcardsopensourceapp/data/local/model/scheduling/SchedulingModels.kt::FsrsCardState.
public enum FsrsCardState: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case new
    case learning
    case review
    case relearning

    public var id: String {
        rawValue
    }
}

// Keep in sync with apps/backend/src/scheduling/workspaceConfig.ts::WorkspaceSchedulerSettings, apps/web/src/types.ts::WorkspaceSchedulerSettings, and apps/android/data/local/src/main/java/com/flashcardsopensourceapp/data/local/model/scheduling/SchedulingModels.kt::WorkspaceSchedulerSettings.
public struct WorkspaceSchedulerSettings: Codable, Hashable, Sendable {
    public let algorithm: String
    public let desiredRetention: Double
    public let learningStepsMinutes: [Int]
    public let relearningStepsMinutes: [Int]
    public let maximumIntervalDays: Int
    public let enableFuzz: Bool
    public let clientUpdatedAt: String
    public let lastModifiedByReplicaId: String
    public let lastOperationId: String
    public let updatedAt: String

    public init(algorithm: String, desiredRetention: Double, learningStepsMinutes: [Int], relearningStepsMinutes: [Int], maximumIntervalDays: Int, enableFuzz: Bool, clientUpdatedAt: String, lastModifiedByReplicaId: String, lastOperationId: String, updatedAt: String) {
        self.algorithm = algorithm
        self.desiredRetention = desiredRetention
        self.learningStepsMinutes = learningStepsMinutes
        self.relearningStepsMinutes = relearningStepsMinutes
        self.maximumIntervalDays = maximumIntervalDays
        self.enableFuzz = enableFuzz
        self.clientUpdatedAt = clientUpdatedAt
        self.lastModifiedByReplicaId = lastModifiedByReplicaId
        self.lastOperationId = lastOperationId
        self.updatedAt = updatedAt
    }
}

public struct ReviewSchedule: Hashable {
    public let dueAt: Date
    public let reps: Int
    public let lapses: Int
    public let fsrsCardState: FsrsCardState
    public let fsrsStepIndex: Int?
    public let fsrsStability: Double
    public let fsrsDifficulty: Double
    public let fsrsLastReviewedAt: Date
    public let fsrsScheduledDays: Int

    public init(dueAt: Date, reps: Int, lapses: Int, fsrsCardState: FsrsCardState, fsrsStepIndex: Int?, fsrsStability: Double, fsrsDifficulty: Double, fsrsLastReviewedAt: Date, fsrsScheduledDays: Int) {
        self.dueAt = dueAt
        self.reps = reps
        self.lapses = lapses
        self.fsrsCardState = fsrsCardState
        self.fsrsStepIndex = fsrsStepIndex
        self.fsrsStability = fsrsStability
        self.fsrsDifficulty = fsrsDifficulty
        self.fsrsLastReviewedAt = fsrsLastReviewedAt
        self.fsrsScheduledDays = fsrsScheduledDays
    }
}
