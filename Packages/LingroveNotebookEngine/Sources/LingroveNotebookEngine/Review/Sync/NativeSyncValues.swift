import Foundation

public enum SyncEntityType: String, Codable, Hashable, Sendable {
    case card
    case deck
    case mediaAsset = "media_asset"
    case workspaceSchedulerSettings = "workspace_scheduler_settings"
    case reviewEvent = "review_event"
}
public enum SyncAction: String, Codable, Hashable, Sendable {
    case upsert
    case append
}

public let legacySyncFastEffortLevel: String = "fast"

public struct LegacyDeckFilterDefinitionSyncPayload: Encodable {
    public let version: Int
    public let effortLevels: [String]
    public let tags: [String]

    public init(filterDefinition: DeckFilterDefinition) {
        self.version = filterDefinition.version
        // TODO(old-mobile-cutoff): Remove legacy effortLevels output during final sync wire-drop cleanup.
        self.effortLevels = []
        self.tags = filterDefinition.tags
    }
}

public struct CardSyncPayload: Codable, Hashable {
    public let cardId: String
    public let frontText: String
    public let backText: String
    public let cardType: String
    public let metadata: CardMetadata
    public let tags: [String]
    public let dueAt: String?
    public let createdAt: String
    public let reps: Int
    public let lapses: Int
    public let fsrsCardState: String
    public let fsrsStepIndex: Int?
    public let fsrsStability: Double?
    public let fsrsDifficulty: Double?
    public let fsrsLastReviewedAt: String?
    public let fsrsScheduledDays: Int?
    public let deletedAt: String?

    public enum CodingKeys: String, CodingKey {
        case cardId
        case frontText
        case backText
        case cardType
        case metadata
        case tags
        case effortLevel
        case dueAt
        case createdAt
        case reps
        case lapses
        case fsrsCardState
        case fsrsStepIndex
        case fsrsStability
        case fsrsDifficulty
        case fsrsLastReviewedAt
        case fsrsScheduledDays
        case deletedAt
    }

    public init(
        cardId: String,
        frontText: String,
        backText: String,
        cardType: String,
        metadata: CardMetadata,
        tags: [String],
        dueAt: String?,
        createdAt: String,
        reps: Int,
        lapses: Int,
        fsrsCardState: String,
        fsrsStepIndex: Int?,
        fsrsStability: Double?,
        fsrsDifficulty: Double?,
        fsrsLastReviewedAt: String?,
        fsrsScheduledDays: Int?,
        deletedAt: String?
    ) {
        self.cardId = cardId
        self.frontText = frontText
        self.backText = backText
        self.cardType = normalizeCardType(cardType: cardType)
        self.metadata = metadata
        self.tags = tags
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.reps = reps
        self.lapses = lapses
        self.fsrsCardState = fsrsCardState
        self.fsrsStepIndex = fsrsStepIndex
        self.fsrsStability = fsrsStability
        self.fsrsDifficulty = fsrsDifficulty
        self.fsrsLastReviewedAt = fsrsLastReviewedAt
        self.fsrsScheduledDays = fsrsScheduledDays
        self.deletedAt = deletedAt
    }

    public init(
        cardId: String,
        frontText: String,
        backText: String,
        tags: [String],
        dueAt: String?,
        createdAt: String,
        reps: Int,
        lapses: Int,
        fsrsCardState: String,
        fsrsStepIndex: Int?,
        fsrsStability: Double?,
        fsrsDifficulty: Double?,
        fsrsLastReviewedAt: String?,
        fsrsScheduledDays: Int?,
        deletedAt: String?
    ) {
        self.init(
            cardId: cardId,
            frontText: frontText,
            backText: backText,
            cardType: basicCardType,
            metadata: makeDefaultCardMetadata(createdAt: createdAt),
            tags: tags,
            dueAt: dueAt,
            createdAt: createdAt,
            reps: reps,
            lapses: lapses,
            fsrsCardState: fsrsCardState,
            fsrsStepIndex: fsrsStepIndex,
            fsrsStability: fsrsStability,
            fsrsDifficulty: fsrsDifficulty,
            fsrsLastReviewedAt: fsrsLastReviewedAt,
            fsrsScheduledDays: fsrsScheduledDays,
            deletedAt: deletedAt
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cardId = try container.decode(String.self, forKey: .cardId)
        self.frontText = try container.decode(String.self, forKey: .frontText)
        self.backText = try container.decode(String.self, forKey: .backText)
        let createdAt = try container.decode(String.self, forKey: .createdAt)
        self.cardType = try decodeCardTypeWithLegacyDefault(from: container, forKey: .cardType)
        self.metadata = try decodeCardMetadataWithLegacyDefault(
            from: container,
            forKey: .metadata,
            createdAt: createdAt
        )
        let tags = try container.decode([String].self, forKey: .tags)
        // TODO(old-mobile-cutoff): Remove legacy effortLevel decode during final sync wire-drop cleanup.
        self.tags = try tagsAppendingLegacyEffortTag(
            tags: tags,
            effortLevel: try container.decodeIfPresent(String.self, forKey: .effortLevel)
        )
        self.dueAt = try container.decodeIfPresent(String.self, forKey: .dueAt)
        self.createdAt = createdAt
        self.reps = try container.decode(Int.self, forKey: .reps)
        self.lapses = try container.decode(Int.self, forKey: .lapses)
        self.fsrsCardState = try container.decode(String.self, forKey: .fsrsCardState)
        self.fsrsStepIndex = try container.decodeIfPresent(Int.self, forKey: .fsrsStepIndex)
        self.fsrsStability = try container.decodeIfPresent(Double.self, forKey: .fsrsStability)
        self.fsrsDifficulty = try container.decodeIfPresent(Double.self, forKey: .fsrsDifficulty)
        self.fsrsLastReviewedAt = try container.decodeIfPresent(String.self, forKey: .fsrsLastReviewedAt)
        self.fsrsScheduledDays = try container.decodeIfPresent(Int.self, forKey: .fsrsScheduledDays)
        self.deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.cardId, forKey: .cardId)
        try container.encode(self.frontText, forKey: .frontText)
        try container.encode(self.backText, forKey: .backText)
        try container.encode(self.cardType, forKey: .cardType)
        try container.encode(self.metadata, forKey: .metadata)
        try container.encode(self.tags, forKey: .tags)
        // TODO(old-mobile-cutoff): Remove legacy effortLevel output during final sync wire-drop cleanup.
        try container.encode(legacySyncFastEffortLevel, forKey: .effortLevel)

        if let dueAt = try canonicalIsoTimestampForSync(cardId: self.cardId, dueAt: self.dueAt) {
            try container.encode(dueAt, forKey: .dueAt)
        } else {
            try container.encodeNil(forKey: .dueAt)
        }

        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encode(self.reps, forKey: .reps)
        try container.encode(self.lapses, forKey: .lapses)
        try container.encode(self.fsrsCardState, forKey: .fsrsCardState)

        if let fsrsStepIndex = self.fsrsStepIndex {
            try container.encode(fsrsStepIndex, forKey: .fsrsStepIndex)
        } else {
            try container.encodeNil(forKey: .fsrsStepIndex)
        }

        if let fsrsStability = self.fsrsStability {
            try container.encode(fsrsStability, forKey: .fsrsStability)
        } else {
            try container.encodeNil(forKey: .fsrsStability)
        }

        if let fsrsDifficulty = self.fsrsDifficulty {
            try container.encode(fsrsDifficulty, forKey: .fsrsDifficulty)
        } else {
            try container.encodeNil(forKey: .fsrsDifficulty)
        }

        if let fsrsLastReviewedAt = self.fsrsLastReviewedAt {
            try container.encode(fsrsLastReviewedAt, forKey: .fsrsLastReviewedAt)
        } else {
            try container.encodeNil(forKey: .fsrsLastReviewedAt)
        }

        if let fsrsScheduledDays = self.fsrsScheduledDays {
            try container.encode(fsrsScheduledDays, forKey: .fsrsScheduledDays)
        } else {
            try container.encodeNil(forKey: .fsrsScheduledDays)
        }

        if let deletedAt = self.deletedAt {
            try container.encode(deletedAt, forKey: .deletedAt)
        } else {
            try container.encodeNil(forKey: .deletedAt)
        }
    }
}

extension CardSyncPayload {
    public init(card: Card) {
        self.cardId = card.cardId
        self.frontText = card.frontText
        self.backText = card.backText
        self.cardType = card.cardType
        self.metadata = card.metadata
        self.tags = card.tags
        self.dueAt = card.dueAt
        self.createdAt = card.createdAt
        self.reps = card.reps
        self.lapses = card.lapses
        self.fsrsCardState = card.fsrsCardState.rawValue
        self.fsrsStepIndex = card.fsrsStepIndex
        self.fsrsStability = card.fsrsStability
        self.fsrsDifficulty = card.fsrsDifficulty
        self.fsrsLastReviewedAt = card.fsrsLastReviewedAt
        self.fsrsScheduledDays = card.fsrsScheduledDays
        self.deletedAt = card.deletedAt
    }
}

public struct DeckSyncPayload: Codable, Hashable {
    public let deckId: String
    public let name: String
    public let filterDefinition: DeckFilterDefinition
    public let createdAt: String
    public let deletedAt: String?

    public enum CodingKeys: String, CodingKey {
        case deckId
        case name
        case filterDefinition
        case createdAt
        case deletedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.deckId, forKey: .deckId)
        try container.encode(self.name, forKey: .name)
        try container.encode(
            LegacyDeckFilterDefinitionSyncPayload(filterDefinition: self.filterDefinition),
            forKey: .filterDefinition
        )
        try container.encode(self.createdAt, forKey: .createdAt)

        if let deletedAt = self.deletedAt {
            try container.encode(deletedAt, forKey: .deletedAt)
        } else {
            try container.encodeNil(forKey: .deletedAt)
        }
    }

    public init(deckId: String, name: String, filterDefinition: DeckFilterDefinition, createdAt: String, deletedAt: String?) {
        self.deckId = deckId
        self.name = name
        self.filterDefinition = filterDefinition
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

extension DeckSyncPayload {
    public init(deck: Deck) {
        self.deckId = deck.deckId
        self.name = deck.name
        self.filterDefinition = deck.filterDefinition
        self.createdAt = deck.createdAt
        self.deletedAt = deck.deletedAt
    }
}

public struct WorkspaceSchedulerSettingsSyncPayload: Codable, Hashable {
    public let algorithm: String
    public let desiredRetention: Double
    public let learningStepsMinutes: [Int]
    public let relearningStepsMinutes: [Int]
    public let maximumIntervalDays: Int
    public let enableFuzz: Bool

    public init(algorithm: String, desiredRetention: Double, learningStepsMinutes: [Int], relearningStepsMinutes: [Int], maximumIntervalDays: Int, enableFuzz: Bool) {
        self.algorithm = algorithm
        self.desiredRetention = desiredRetention
        self.learningStepsMinutes = learningStepsMinutes
        self.relearningStepsMinutes = relearningStepsMinutes
        self.maximumIntervalDays = maximumIntervalDays
        self.enableFuzz = enableFuzz
    }
}

extension WorkspaceSchedulerSettingsSyncPayload {
    public init(settings: WorkspaceSchedulerSettings) {
        self.algorithm = settings.algorithm
        self.desiredRetention = settings.desiredRetention
        self.learningStepsMinutes = settings.learningStepsMinutes
        self.relearningStepsMinutes = settings.relearningStepsMinutes
        self.maximumIntervalDays = settings.maximumIntervalDays
        self.enableFuzz = settings.enableFuzz
    }
}

public struct ReviewEventSyncPayload: Codable, Hashable {
    public let reviewEventId: String
    public let cardId: String
    public let installationId: String
    public let clientEventId: String
    public let rating: Int
    public let reviewedAtClient: String
    public let reviewedTimeZone: String?

    public enum CodingKeys: String, CodingKey {
        case reviewEventId
        case cardId
        case installationId
        case clientEventId
        case rating
        case reviewedAtClient
        case reviewedTimeZone
    }

    public init(
        reviewEventId: String,
        cardId: String,
        installationId: String,
        clientEventId: String,
        rating: Int,
        reviewedAtClient: String,
        reviewedTimeZone: String?
    ) {
        self.reviewEventId = reviewEventId
        self.cardId = cardId
        self.installationId = installationId
        self.clientEventId = clientEventId
        self.rating = rating
        self.reviewedAtClient = reviewedAtClient
        self.reviewedTimeZone = reviewedTimeZone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reviewEventId = try container.decode(String.self, forKey: .reviewEventId)
        self.cardId = try container.decode(String.self, forKey: .cardId)
        self.installationId = try container.decode(String.self, forKey: .installationId)
        self.clientEventId = try container.decode(String.self, forKey: .clientEventId)
        self.rating = try container.decode(Int.self, forKey: .rating)
        self.reviewedAtClient = try container.decode(String.self, forKey: .reviewedAtClient)
        self.reviewedTimeZone = try container.decodeIfPresent(String.self, forKey: .reviewedTimeZone)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.reviewEventId, forKey: .reviewEventId)
        try container.encode(self.cardId, forKey: .cardId)
        try container.encode(self.clientEventId, forKey: .clientEventId)
        try container.encode(self.rating, forKey: .rating)
        try container.encode(self.reviewedAtClient, forKey: .reviewedAtClient)
        try container.encodeIfPresent(self.reviewedTimeZone, forKey: .reviewedTimeZone)
    }
}

public struct MediaAssetSyncPayload: Codable, Hashable {
    public let mediaAssetId: String
    public let workspaceId: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let sha256: String
    public let sourceUrl: String?
    public let createdAt: String
    public let deletedAt: String?

    public enum CodingKeys: String, CodingKey {
        case mediaAssetId
        case workspaceId
        case mimeType
        case sizeBytes
        case sha256
        case sourceUrl
        case createdAt
        case deletedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.mediaAssetId, forKey: .mediaAssetId)
        try container.encode(self.workspaceId, forKey: .workspaceId)
        try container.encode(self.mimeType, forKey: .mimeType)
        try container.encode(self.sizeBytes, forKey: .sizeBytes)
        try container.encode(self.sha256, forKey: .sha256)
        if let sourceUrl = self.sourceUrl {
            try container.encode(sourceUrl, forKey: .sourceUrl)
        } else {
            try container.encodeNil(forKey: .sourceUrl)
        }
        try container.encode(self.createdAt, forKey: .createdAt)
        if let deletedAt = self.deletedAt {
            try container.encode(deletedAt, forKey: .deletedAt)
        } else {
            try container.encodeNil(forKey: .deletedAt)
        }
    }

    public init(mediaAssetId: String, workspaceId: String, mimeType: String, sizeBytes: Int64, sha256: String, sourceUrl: String?, createdAt: String, deletedAt: String?) {
        self.mediaAssetId = mediaAssetId
        self.workspaceId = workspaceId
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.sourceUrl = sourceUrl
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

extension MediaAssetSyncPayload {
    public init(mediaAsset: MediaAsset) {
        self.mediaAssetId = mediaAsset.mediaAssetId
        self.workspaceId = mediaAsset.workspaceId
        self.mimeType = mediaAsset.mimeType
        self.sizeBytes = mediaAsset.sizeBytes
        self.sha256 = mediaAsset.sha256
        self.sourceUrl = mediaAsset.sourceUrl
        self.createdAt = mediaAsset.createdAt
        self.deletedAt = mediaAsset.deletedAt
    }
}

public enum SyncOperationPayload: Hashable {
    case card(CardSyncPayload)
    case deck(DeckSyncPayload)
    case mediaAsset(MediaAssetSyncPayload)
    case workspaceSchedulerSettings(WorkspaceSchedulerSettingsSyncPayload)
    case reviewEvent(ReviewEventSyncPayload)
}

public struct SyncOperation: Hashable {
    public let operationId: String
    public let entityType: SyncEntityType
    public let entityId: String
    public let action: SyncAction
    public let clientUpdatedAt: String
    public let payload: SyncOperationPayload

    public init(operationId: String, entityType: SyncEntityType, entityId: String, action: SyncAction, clientUpdatedAt: String, payload: SyncOperationPayload) {
        self.operationId = operationId
        self.entityType = entityType
        self.entityId = entityId
        self.action = action
        self.clientUpdatedAt = clientUpdatedAt
        self.payload = payload
    }
}

/// Mirrors one `/sync/push` operation result from `apps/backend/src/sync/contracts/types.ts`.


/// Mirrors the `/sync/push` response from `apps/backend/src/sync/contracts/types.ts`.


/// Local hot-state bootstrap entry derived from backend bootstrap responses.
public enum SyncBootstrapEntryPayload: Hashable {
    case card(Card)
    case deck(Deck)
    case mediaAsset(MediaAsset)
    case workspaceSchedulerSettings(WorkspaceSchedulerSettings)
}

/// Local hot-state bootstrap entry derived from `/sync/bootstrap`.
public struct SyncBootstrapEntry: Hashable {
    public let entityType: SyncEntityType
    public let entityId: String
    public let action: SyncAction
    public let payload: SyncBootstrapEntryPayload

    public init(entityType: SyncEntityType, entityId: String, action: SyncAction, payload: SyncBootstrapEntryPayload) {
        self.entityType = entityType
        self.entityId = entityId
        self.action = action
        self.payload = payload
    }
}

/// Local hot-state delta payload derived from `/sync/pull`.
public enum SyncChangePayload: Hashable {
    case card(Card)
    case deck(Deck)
    case mediaAsset(MediaAsset)
    case workspaceSchedulerSettings(WorkspaceSchedulerSettings)
}

/// Local hot-state delta derived from `/sync/pull`.
public struct SyncChange: Hashable {
    public let changeId: Int64
    public let entityType: SyncEntityType
    public let entityId: String
    public let action: SyncAction
    public let payload: SyncChangePayload

    public init(changeId: Int64, entityType: SyncEntityType, entityId: String, action: SyncAction, payload: SyncChangePayload) {
        self.changeId = changeId
        self.entityType = entityType
        self.entityId = entityId
        self.action = action
        self.payload = payload
    }
}

/// Local representation of the `/sync/pull` response.


/// Local representation of the `/sync/bootstrap` pull response.


/// Local representation of the `/sync/bootstrap` push response.


/// Local representation of the `/sync/review-history/pull` response.


/// Local representation of the `/sync/review-history/import` response.


public struct PersistedOutboxEntry: Hashable {
    public let operationId: String
    public let workspaceId: String
    public let createdAt: String
    public let attemptCount: Int
    public let lastError: String
    public let reviewScheduleImpact: Bool
    public let operation: SyncOperation

    public init(operationId: String, workspaceId: String, createdAt: String, attemptCount: Int, lastError: String, reviewScheduleImpact: Bool, operation: SyncOperation) {
        self.operationId = operationId
        self.workspaceId = workspaceId
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.reviewScheduleImpact = reviewScheduleImpact
        self.operation = operation
    }
}
