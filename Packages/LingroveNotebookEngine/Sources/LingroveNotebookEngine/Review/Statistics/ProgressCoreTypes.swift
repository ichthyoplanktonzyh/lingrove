import Foundation

public let progressDaysPerWeek: Int = 7

public struct ProgressDay: Codable, Hashable, Identifiable, Sendable {
    public let date: String
    public let reviewCount: Int
    public let againCount: Int
    public let hardCount: Int
    public let goodCount: Int
    public let easyCount: Int

    public var id: String {
        self.date
    }

    public init(date: String, reviewCount: Int, againCount: Int, hardCount: Int, goodCount: Int, easyCount: Int) {
        self.date = date
        self.reviewCount = reviewCount
        self.againCount = againCount
        self.hardCount = hardCount
        self.goodCount = goodCount
        self.easyCount = easyCount
    }
}

public struct ProgressReviewRatingCounts: Hashable, Sendable {
    public let againCount: Int
    public let hardCount: Int
    public let goodCount: Int
    public let easyCount: Int

    public var reviewCount: Int {
        self.againCount + self.hardCount + self.goodCount + self.easyCount
    }

    public init(againCount: Int, hardCount: Int, goodCount: Int, easyCount: Int) {
        self.againCount = againCount
        self.hardCount = hardCount
        self.goodCount = goodCount
        self.easyCount = easyCount
    }
}

public struct ProgressSummary: Codable, Hashable, Sendable {
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let hasReviewedToday: Bool
    public let lastReviewedOn: String?
    public let activeReviewDays: Int
    public let streakFreeze: ProgressStreakFreeze

    public init(currentStreakDays: Int, longestStreakDays: Int, hasReviewedToday: Bool, lastReviewedOn: String?, activeReviewDays: Int, streakFreeze: ProgressStreakFreeze) {
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.hasReviewedToday = hasReviewedToday
        self.lastReviewedOn = lastReviewedOn
        self.activeReviewDays = activeReviewDays
        self.streakFreeze = streakFreeze
    }
}

public struct ProgressStreakFreeze: Codable, Hashable, Sendable {
    public let availableCredits: Int
    public let capacity: Int
    public let balanceUnits: Int
    public let unitsPerCredit: Int
    public let earnedUnitsPerStreakDay: Int
    public let nextCreditProgressUnits: Int
    public let nextCreditRequiredUnits: Int

    public init(availableCredits: Int, capacity: Int, balanceUnits: Int, unitsPerCredit: Int, earnedUnitsPerStreakDay: Int, nextCreditProgressUnits: Int, nextCreditRequiredUnits: Int) {
        self.availableCredits = availableCredits
        self.capacity = capacity
        self.balanceUnits = balanceUnits
        self.unitsPerCredit = unitsPerCredit
        self.earnedUnitsPerStreakDay = earnedUnitsPerStreakDay
        self.nextCreditProgressUnits = nextCreditProgressUnits
        self.nextCreditRequiredUnits = nextCreditRequiredUnits
    }
}

public enum ProgressStreakDayState: String, Codable, Hashable, Sendable {
    case reviewed
    case frozen
    case missed
    case pending
}

public struct ProgressStreakDay: Codable, Hashable, Identifiable, Sendable {
    public let date: String
    public let state: ProgressStreakDayState

    public var id: String {
        self.date
    }

    public init(date: String, state: ProgressStreakDayState) {
        self.date = date
        self.state = state
    }
}

public struct ProgressReviewHistoryWatermark: Codable, Hashable, Sendable {
    public let workspaceId: String
    public let reviewSequenceId: Int64

    public enum CodingKeys: String, CodingKey {
        case workspaceId
        case reviewSequenceId
    }

    public init(
        workspaceId: String,
        reviewSequenceId: Int64
    ) {
        self.workspaceId = workspaceId
        self.reviewSequenceId = reviewSequenceId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reviewSequenceId = try container.decode(Int64.self, forKey: .reviewSequenceId)
        guard reviewSequenceId >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .reviewSequenceId,
                in: container,
                debugDescription: "reviewSequenceId must not be negative"
            )
        }

        self.init(
            workspaceId: try container.decode(String.self, forKey: .workspaceId),
            reviewSequenceId: reviewSequenceId
        )
    }
}

private func decodeProgressReviewHistoryWatermarksIfAvailable<Key: CodingKey>(
    container: KeyedDecodingContainer<Key>,
    key: Key
) throws -> [ProgressReviewHistoryWatermark] {
    guard container.contains(key) else {
        return []
    }

    return try container.decode([ProgressReviewHistoryWatermark].self, forKey: key)
}

public struct UserProgressSummary: Codable, Hashable, Sendable {
    public let timeZone: String?
    public let summary: ProgressSummary
    public let generatedAt: String?
    public let reviewHistoryWatermarks: [ProgressReviewHistoryWatermark]

    public enum CodingKeys: String, CodingKey {
        case timeZone
        case summary
        case generatedAt
        case reviewHistoryWatermarks
        case currentStreakDays
        case longestStreakDays
        case hasReviewedToday
        case lastReviewedOn
        case activeReviewDays
        case streakFreeze
    }

    public init(
        timeZone: String?,
        summary: ProgressSummary,
        generatedAt: String?,
        reviewHistoryWatermarks: [ProgressReviewHistoryWatermark]
    ) {
        self.timeZone = timeZone
        self.summary = summary
        self.generatedAt = generatedAt
        self.reviewHistoryWatermarks = reviewHistoryWatermarks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.summary) {
            self.init(
                timeZone: try container.decodeIfPresent(String.self, forKey: .timeZone),
                summary: try container.decode(ProgressSummary.self, forKey: .summary),
                generatedAt: try container.decodeIfPresent(String.self, forKey: .generatedAt),
                reviewHistoryWatermarks: try decodeProgressReviewHistoryWatermarksIfAvailable(
                    container: container,
                    key: .reviewHistoryWatermarks
                )
            )
            return
        }

        self.init(
            timeZone: try container.decodeIfPresent(String.self, forKey: .timeZone),
            summary: ProgressSummary(
                currentStreakDays: try container.decode(Int.self, forKey: .currentStreakDays),
                longestStreakDays: try container.decode(Int.self, forKey: .longestStreakDays),
                hasReviewedToday: try container.decode(Bool.self, forKey: .hasReviewedToday),
                lastReviewedOn: try container.decodeIfPresent(String.self, forKey: .lastReviewedOn),
                activeReviewDays: try container.decode(Int.self, forKey: .activeReviewDays),
                streakFreeze: try container.decode(ProgressStreakFreeze.self, forKey: .streakFreeze)
            ),
            generatedAt: try container.decodeIfPresent(String.self, forKey: .generatedAt),
            reviewHistoryWatermarks: try decodeProgressReviewHistoryWatermarksIfAvailable(
                container: container,
                key: .reviewHistoryWatermarks
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.timeZone, forKey: .timeZone)
        try container.encode(self.summary, forKey: .summary)
        try container.encodeIfPresent(self.generatedAt, forKey: .generatedAt)
        try container.encode(self.reviewHistoryWatermarks, forKey: .reviewHistoryWatermarks)
    }
}

public struct UserProgressSeries: Codable, Hashable, Sendable {
    public let timeZone: String
    public let from: String
    public let to: String
    public let dailyReviews: [ProgressDay]
    public let streakDays: [ProgressStreakDay]
    public let summary: ProgressSummary?
    public let generatedAt: String?
    public let reviewHistoryWatermarks: [ProgressReviewHistoryWatermark]

    public enum CodingKeys: String, CodingKey {
        case timeZone
        case from
        case to
        case dailyReviews
        case streakDays
        case summary
        case generatedAt
        case reviewHistoryWatermarks
    }

    public init(
        timeZone: String,
        from: String,
        to: String,
        dailyReviews: [ProgressDay],
        streakDays: [ProgressStreakDay],
        summary: ProgressSummary?,
        generatedAt: String?,
        reviewHistoryWatermarks: [ProgressReviewHistoryWatermark]
    ) {
        self.timeZone = timeZone
        self.from = from
        self.to = to
        self.dailyReviews = dailyReviews
        self.streakDays = streakDays
        self.summary = summary
        self.generatedAt = generatedAt
        self.reviewHistoryWatermarks = reviewHistoryWatermarks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeZone: try container.decode(String.self, forKey: .timeZone),
            from: try container.decode(String.self, forKey: .from),
            to: try container.decode(String.self, forKey: .to),
            dailyReviews: try container.decode([ProgressDay].self, forKey: .dailyReviews),
            streakDays: try container.decode([ProgressStreakDay].self, forKey: .streakDays),
            summary: try container.decodeIfPresent(ProgressSummary.self, forKey: .summary),
            generatedAt: try container.decodeIfPresent(String.self, forKey: .generatedAt),
            reviewHistoryWatermarks: try decodeProgressReviewHistoryWatermarksIfAvailable(
                container: container,
                key: .reviewHistoryWatermarks
            )
        )
    }
}

public enum ReviewScheduleBucketKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case new
    case today
    case days1To7
    case days8To30
    case days31To90
    case days91To360
    case years1To2
    case later

    public static let stableOrder: [ReviewScheduleBucketKey] = [
        .new,
        .today,
        .days1To7,
        .days8To30,
        .days31To90,
        .days91To360,
        .years1To2,
        .later,
    ]

    public var id: String {
        self.rawValue
    }
}

public struct ReviewScheduleBucket: Codable, Hashable, Identifiable, Sendable {
    public let key: ReviewScheduleBucketKey
    public let count: Int

    public var id: ReviewScheduleBucketKey {
        self.key
    }

    public init(key: ReviewScheduleBucketKey, count: Int) {
        self.key = key
        self.count = count
    }
}

public struct UserReviewSchedule: Codable, Hashable, Sendable {
    public let timeZone: String
    public let generatedAt: String?
    public let reviewHistoryWatermarks: [ProgressReviewHistoryWatermark]
    public let totalCards: Int
    public let buckets: [ReviewScheduleBucket]

    public enum CodingKeys: String, CodingKey {
        case timeZone
        case generatedAt
        case reviewHistoryWatermarks
        case totalCards
        case buckets
    }

    public init(
        timeZone: String,
        generatedAt: String?,
        reviewHistoryWatermarks: [ProgressReviewHistoryWatermark],
        totalCards: Int,
        buckets: [ReviewScheduleBucket]
    ) {
        self.timeZone = timeZone
        self.generatedAt = generatedAt
        self.reviewHistoryWatermarks = reviewHistoryWatermarks
        self.totalCards = totalCards
        self.buckets = buckets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeZone: try container.decode(String.self, forKey: .timeZone),
            generatedAt: try container.decodeIfPresent(String.self, forKey: .generatedAt),
            reviewHistoryWatermarks: try decodeProgressReviewHistoryWatermarksIfAvailable(
                container: container,
                key: .reviewHistoryWatermarks
            ),
            totalCards: try container.decode(Int.self, forKey: .totalCards),
            buckets: try container.decode([ReviewScheduleBucket].self, forKey: .buckets)
        )
    }
}

public enum ProgressSourceState: String, Codable, Hashable, Sendable {
    case localOnly = "local_only"
    case serverBase = "server_base"
    case serverBaseWithPendingLocalOverlay = "server_base_with_pending_local_overlay"
}

public enum ProgressPresentationError: LocalizedError {
    case duplicateDay(String)
    case duplicateStreakDay(String)
    case missingStreakDay(String)
    case inconsistentStreakDay(localDate: String, reviewCount: Int, streakState: ProgressStreakDayState)
    case invalidLocalDate(String)
    case invalidTimeZone(String)
    case invalidRange(String, String)
    case negativeReviewCount(String, Int)
    case negativeReviewRatingCount(localDate: String, rating: String, count: Int)
    case reviewCountBreakdownMismatch(localDate: String, reviewCount: Int, ratingTotal: Int)
    case duplicateReviewScheduleBucket(String)
    case invalidReviewScheduleBucketOrder([String])
    case negativeReviewScheduleBucketCount(String, Int)
    case reviewScheduleTotalMismatch(expected: Int, actual: Int)
    case summaryMetadataMismatch(expectedTimeZone: String, actualTimeZone: String)
    case seriesMetadataMismatch(expected: ProgressScopeKey, actualTimeZone: String, actualFrom: String, actualTo: String)
    case reviewScheduleMetadataMismatch(expectedTimeZone: String, actualTimeZone: String)

    public var errorDescription: String? {
        switch self {
        case .duplicateDay(let localDate):
            return "Progress contained duplicate daily entries for \(localDate)."
        case .duplicateStreakDay(let localDate):
            return "Progress contained duplicate streak entries for \(localDate)."
        case .missingStreakDay(let localDate):
            return "Progress did not contain a streak entry for \(localDate)."
        case .inconsistentStreakDay(let localDate, let reviewCount, let streakState):
            return "Progress streak entry for \(localDate) mismatched review count \(reviewCount): \(streakState.rawValue)."
        case .invalidLocalDate(let localDate):
            return "Progress contained an invalid local date: \(localDate)."
        case .invalidTimeZone(let timeZoneIdentifier):
            return "Progress contained an invalid timezone identifier: \(timeZoneIdentifier)."
        case .invalidRange(let from, let to):
            return "Progress contained an invalid date range from \(from) to \(to)."
        case .negativeReviewCount(let localDate, let reviewCount):
            return "Progress contained a negative review count for \(localDate): \(reviewCount)."
        case .negativeReviewRatingCount(let localDate, let rating, let count):
            return "Progress contained a negative \(rating) review count for \(localDate): \(count)."
        case .reviewCountBreakdownMismatch(let localDate, let reviewCount, let ratingTotal):
            return "Progress review count for \(localDate) must equal its rating-count total. reviewCount=\(reviewCount), ratingTotal=\(ratingTotal)."
        case .duplicateReviewScheduleBucket(let bucketKey):
            return "Review schedule contained a duplicate bucket: \(bucketKey)."
        case .invalidReviewScheduleBucketOrder(let bucketKeys):
            return "Review schedule bucket order is invalid: \(bucketKeys.joined(separator: ", "))."
        case .negativeReviewScheduleBucketCount(let bucketKey, let count):
            return "Review schedule contained a negative count for \(bucketKey): \(count)."
        case .reviewScheduleTotalMismatch(let expected, let actual):
            return "Review schedule totalCards mismatched bucket counts. Expected \(expected), received \(actual)."
        case .summaryMetadataMismatch(let expectedTimeZone, let actualTimeZone):
            return "Progress summary metadata mismatched the current scope. Expected \(expectedTimeZone), received \(actualTimeZone)."
        case .seriesMetadataMismatch(let expected, let actualTimeZone, let actualFrom, let actualTo):
            return "Progress series metadata mismatched the current scope. Expected \(expected.timeZone) \(expected.from)...\(expected.to), received \(actualTimeZone) \(actualFrom)...\(actualTo)."
        case .reviewScheduleMetadataMismatch(let expectedTimeZone, let actualTimeZone):
            return "Review schedule metadata mismatched the current scope. Expected \(expectedTimeZone), received \(actualTimeZone)."
        }
    }
}

public func makeProgressSummary(
    reviewDates: Set<String>,
    timeZone: String,
    generatedAt: Date
) throws -> ProgressSummary {
    let sortedReviewDates = reviewDates.sorted()
    let today = try progressTimeZoneLocalDateString(
        date: generatedAt,
        timeZoneIdentifier: timeZone
    )
    let lastReviewedOn = sortedReviewDates.last
    let streakFreezeEvaluation = try evaluateProgressStreakFreeze(
        sortedActiveReviewLocalDates: sortedReviewDates,
        today: today,
        policy: progressStreakFreezePolicy
    )
    return ProgressSummary(
        currentStreakDays: streakFreezeEvaluation.currentStreakDays,
        longestStreakDays: streakFreezeEvaluation.longestStreakDays,
        hasReviewedToday: reviewDates.contains(today),
        lastReviewedOn: lastReviewedOn,
        activeReviewDays: sortedReviewDates.count,
        streakFreeze: streakFreezeEvaluation.streakFreeze
    )
}

public func makeProgressSeries(
    timeZone: String,
    from: String,
    to: String,
    dailyReviews: [ProgressDay],
    streakDays: [ProgressStreakDay],
    summary: ProgressSummary?,
    generatedAt: String?,
    reviewHistoryWatermarks: [ProgressReviewHistoryWatermark]
) -> UserProgressSeries {
    UserProgressSeries(
        timeZone: timeZone,
        from: from,
        to: to,
        dailyReviews: dailyReviews,
        streakDays: streakDays,
        summary: summary,
        generatedAt: generatedAt,
        reviewHistoryWatermarks: reviewHistoryWatermarks
    )
}

public func makeReviewSchedule(
    timeZone: String,
    generatedAt: String?,
    reviewHistoryWatermarks: [ProgressReviewHistoryWatermark],
    totalCards: Int,
    buckets: [ReviewScheduleBucket]
) -> UserReviewSchedule {
    UserReviewSchedule(
        timeZone: timeZone,
        generatedAt: generatedAt,
        reviewHistoryWatermarks: reviewHistoryWatermarks,
        totalCards: totalCards,
        buckets: buckets
    )
}

public func validateProgressSummaryMetadata(
    summary: UserProgressSummary,
    scopeKey: ProgressSummaryScopeKey
) throws {
    try validateProgressSummaryStreakContract(summary: summary.summary)

    guard let actualTimeZone = summary.timeZone else {
        return
    }

    guard actualTimeZone == scopeKey.timeZone else {
        throw ProgressPresentationError.summaryMetadataMismatch(
            expectedTimeZone: scopeKey.timeZone,
            actualTimeZone: actualTimeZone
        )
    }
}

public func validateReviewSchedule(
    schedule: UserReviewSchedule,
    scopeKey: ReviewScheduleScopeKey
) throws {
    guard schedule.timeZone == scopeKey.timeZone else {
        throw ProgressPresentationError.reviewScheduleMetadataMismatch(
            expectedTimeZone: scopeKey.timeZone,
            actualTimeZone: schedule.timeZone
        )
    }

    let actualKeys = schedule.buckets.map(\.key)
    guard actualKeys == ReviewScheduleBucketKey.stableOrder else {
        throw ProgressPresentationError.invalidReviewScheduleBucketOrder(
            actualKeys.map(\.rawValue)
        )
    }

    var seenKeys: Set<ReviewScheduleBucketKey> = []
    var bucketCountSum = 0
    for bucket in schedule.buckets {
        guard seenKeys.insert(bucket.key).inserted else {
            throw ProgressPresentationError.duplicateReviewScheduleBucket(bucket.key.rawValue)
        }

        guard bucket.count >= 0 else {
            throw ProgressPresentationError.negativeReviewScheduleBucketCount(
                bucket.key.rawValue,
                bucket.count
            )
        }

        bucketCountSum += bucket.count
    }

    guard schedule.totalCards == bucketCountSum else {
        throw ProgressPresentationError.reviewScheduleTotalMismatch(
            expected: bucketCountSum,
            actual: schedule.totalCards
        )
    }
}

private func calculateProgressCurrentStreakDays(
    reviewDates: Set<String>,
    todayLocalDate: String
) throws -> Int {
    var currentDate = reviewDates.contains(todayLocalDate)
        ? todayLocalDate
        : try progressShiftLocalDate(value: todayLocalDate, offsetDays: -1)
    var streakDayCount = 0

    while reviewDates.contains(currentDate) {
        streakDayCount += 1
        currentDate = try progressShiftLocalDate(value: currentDate, offsetDays: -1)
    }

    return streakDayCount
}

private func progressShiftLocalDate(value: String, offsetDays: Int) throws -> String {
    let calendar = Calendar(identifier: .gregorian)
    let baseDate = try progressDate(localDate: value, calendar: calendar)
    guard let nextDate = calendar.date(byAdding: .day, value: offsetDays, to: baseDate) else {
        throw ProgressPresentationError.invalidLocalDate(value)
    }

    let nextComponents = calendar.dateComponents([.year, .month, .day], from: nextDate)
    guard
        let year = nextComponents.year,
        let month = nextComponents.month,
        let day = nextComponents.day
    else {
        throw ProgressPresentationError.invalidLocalDate(value)
    }

    return String(
        format: "%04d-%02d-%02d",
        year,
        month,
        day
    )
}

private func progressTimeZoneLocalDateString(
    date: Date,
    timeZoneIdentifier: String
) throws -> String {
    guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
        throw ProgressPresentationError.invalidLocalDate(timeZoneIdentifier)
    }

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

public func progressDate(localDate: String, calendar: Calendar) throws -> Date {
    guard let date = progressStrictDate(localDate: localDate, calendar: calendar) else {
        throw ProgressPresentationError.invalidLocalDate(localDate)
    }

    return date
}

public func progressLocalDateString(date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)

    guard let year = components.year, let month = components.month, let day = components.day else {
        preconditionFailure("Progress local date components are unavailable")
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}
