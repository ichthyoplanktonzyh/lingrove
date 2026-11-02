import Foundation

public struct ProgressScopeKey: Codable, Hashable, Sendable {
    public let cloudState: CloudAccountState?
    public let linkedUserId: String?
    /// Tracks the canonical cached workspace membership that contributes to aggregated progress.
    /// Switching the active workspace keeps this stable, but create/delete/merge membership changes rotate the scope.
    public let workspaceMembershipKey: String
    public let timeZone: String
    public let from: String
    public let to: String

    public var storageKey: String {
        let cloudStateKey = self.cloudState?.rawValue ?? "none"
        let linkedUserIdKey = self.linkedUserId ?? "none"
        return [
            cloudStateKey,
            linkedUserIdKey,
            self.workspaceMembershipKey,
            self.timeZone,
            self.from,
            self.to,
        ].joined(separator: "|")
    }

    public init(cloudState: CloudAccountState?, linkedUserId: String?, workspaceMembershipKey: String, timeZone: String, from: String, to: String) {
        self.cloudState = cloudState
        self.linkedUserId = linkedUserId
        self.workspaceMembershipKey = workspaceMembershipKey
        self.timeZone = timeZone
        self.from = from
        self.to = to
    }
}

public struct ProgressSummaryScopeKey: Codable, Hashable, Sendable {
    public let cloudState: CloudAccountState?
    public let linkedUserId: String?
    public let workspaceMembershipKey: String
    public let timeZone: String
    /// Summary fields such as hasReviewedToday and currentStreakDays are relative to a local "today".
    /// Keep the cache keyed by that local date so yesterday's summary is never reused after midnight.
    public let referenceLocalDate: String

    public var storageKey: String {
        let cloudStateKey = self.cloudState?.rawValue ?? "none"
        let linkedUserIdKey = self.linkedUserId ?? "none"
        return [
            cloudStateKey,
            linkedUserIdKey,
            self.workspaceMembershipKey,
            self.timeZone,
            self.referenceLocalDate,
        ].joined(separator: "|")
    }

    public init(cloudState: CloudAccountState?, linkedUserId: String?, workspaceMembershipKey: String, timeZone: String, referenceLocalDate: String) {
        self.cloudState = cloudState
        self.linkedUserId = linkedUserId
        self.workspaceMembershipKey = workspaceMembershipKey
        self.timeZone = timeZone
        self.referenceLocalDate = referenceLocalDate
    }
}

public struct ProgressLeaderboardScopeKey: Codable, Hashable, Sendable {
    public let cloudState: CloudAccountState?
    public let linkedUserId: String?
    /// Anonymous display names in the cached payload are server-generated from the
    /// request locale, so a device language change must rotate the cache scope.
    public let localeIdentifier: String

    public var storageKey: String {
        let cloudStateKey = self.cloudState?.rawValue ?? "none"
        let linkedUserIdKey = self.linkedUserId ?? "none"
        return [
            cloudStateKey,
            linkedUserIdKey,
            self.localeIdentifier,
        ].joined(separator: "|")
    }

    public init(cloudState: CloudAccountState?, linkedUserId: String?, localeIdentifier: String) {
        self.cloudState = cloudState
        self.linkedUserId = linkedUserId
        self.localeIdentifier = localeIdentifier
    }
}

public struct ReviewScheduleScopeKey: Codable, Hashable, Sendable {
    public let cloudState: CloudAccountState?
    public let linkedUserId: String?
    public let workspaceMembershipKey: String
    public let timeZone: String
    /// Schedule buckets are relative to the user's local "today".
    /// Keep the cache keyed by that local date so "Today" rotates cleanly after midnight.
    public let referenceLocalDate: String

    public var storageKey: String {
        let cloudStateKey = self.cloudState?.rawValue ?? "none"
        let linkedUserIdKey = self.linkedUserId ?? "none"
        return [
            cloudStateKey,
            linkedUserIdKey,
            self.workspaceMembershipKey,
            self.timeZone,
            self.referenceLocalDate,
        ].joined(separator: "|")
    }

    public init(cloudState: CloudAccountState?, linkedUserId: String?, workspaceMembershipKey: String, timeZone: String, referenceLocalDate: String) {
        self.cloudState = cloudState
        self.linkedUserId = linkedUserId
        self.workspaceMembershipKey = workspaceMembershipKey
        self.timeZone = timeZone
        self.referenceLocalDate = referenceLocalDate
    }
}
