// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W4_PROGRESS_REUSE_MAP.md.
import Foundation

/// Notebook-specific binding of Nibomo's pure date/streak/schedule rules. The SQL reader owns
/// admission and cancellation; this stateless reducer owns count consistency. It runs on the
/// reader actor, never MainActor, and evaluates every section against the same frozen clock.
enum NotebookProgressAggregation {
    static func make(scope: NotebookProgressScope, events: [NotebookProgressEvent],
                     dueExercises: [NotebookProgressDueExercise], undoneReviews: Int,
                     enrolledSenses: Int, activeSenses: Int, exercises: Int,
                     now: Date, userCalendar: Calendar) throws -> NotebookProgressSnapshot {
        var calendar = makeProgressStoreCalendar(timeZone: userCalendar.timeZone)
        calendar.locale = userCalendar.locale
        calendar.firstWeekday = userCalendar.firstWeekday
        calendar.minimumDaysInFirstWeek = userCalendar.minimumDaysInFirstWeek
        let range = try makeProgressRequestRange(now: now, timeZone: calendar.timeZone,
            dayCount: recentProgressHistoryDayCount)
        var counts: [String: [Int]] = [:]
        var seen = Set<String>()
        var totalReviews = 0
        for event in events {
            try Task.checkCancellation()
            // SQL uses EXISTS rather than joins so merged enrollment relationships cannot
            // multiply rows. This identity check also keeps future adapters from double-counting.
            guard seen.insert(event.id).inserted else { continue }
            guard let date = parseIsoTimestamp(value: event.reviewedAt) else {
                throw LocalStoreError.validation("Notebook progress contains an invalid review timestamp")
            }
            guard date <= now else { continue }
            // Nibomo records a review's local day in its recorded timezone. Travel does not
            // move yesterday's work into another day; old rows without a zone use this read's.
            let zone = try event.timeZone.map(progressTimeZone(identifier:)) ?? calendar.timeZone
            let eventCalendar = makeProgressStoreCalendar(timeZone: zone)
            let localDate = progressLocalDateStringForStore(date: date, calendar: eventCalendar)
            totalReviews += 1
            // A review recorded east of the current timezone can already be tomorrow there.
            // It remains completed work, but never paints a future calendar day as reviewed.
            guard localDate <= range.to else { continue }
            var dayCounts = counts[localDate] ?? [0, 0, 0, 0]
            dayCounts[event.rating.rawValue] += 1
            counts[localDate] = dayCounts
        }
        let activeDates = Set(counts.keys)
        // The shared algorithm accepts a zero-capacity policy. We reuse its pending-today,
        // longest-run and civil-day behavior without manufacturing streak-freeze credits.
        let streak = try evaluateProgressStreakFreeze(sortedActiveReviewLocalDates: activeDates.sorted(),
            today: range.to, policy: .init(startCapacity: 0, maxCapacity: 0,
                unitsPerCredit: 1, earnedUnitsPerStreakDay: 0))
        let days = try makeZeroFilledProgressDays(requestRange: range).map { day in
            let values = counts[day.date] ?? [0, 0, 0, 0]
            return ProgressDay(date: day.date, reviewCount: values.reduce(0, +),
                againCount: values[0], hardCount: values[1], goodCount: values[2], easyCount: values[3])
        }
        let boundaries = try makeReviewScheduleBucketBoundaries(referenceLocalDate: range.to,
            timeZone: calendar.timeZone)
        var buckets: [ReviewScheduleBucketKey: Int] = [:]
        for exercise in dueExercises {
            try Task.checkCancellation()
            let key = bucket(dueMillis: exercise.dueMillis, boundaries: boundaries)
            buckets[key, default: 0] += 1
        }
        return .init(scope: scope, now: now, calendar: calendar, range: range,
            summary: .init(currentStreakDays: streak.currentStreakDays,
                longestStreakDays: streak.longestStreakDays, hasReviewedToday: activeDates.contains(range.to),
                lastReviewedOn: activeDates.max(), activeReviewDays: activeDates.count,
                streakFreeze: streak.streakFreeze),
            dailyReviews: days, streakDays: makeProgressStreakDays(range: days.map(\.date),
                activeReviewDates: activeDates, evaluatedStreakDays: streak.streakDays, today: range.to),
            schedule: .init(timeZone: calendar.timeZone.identifier, generatedAt: formatIsoTimestamp(date: now),
                reviewHistoryWatermarks: [], totalCards: dueExercises.count,
                buckets: ReviewScheduleBucketKey.stableOrder.map { .init(key: $0, count: buckets[$0] ?? 0) }),
            totalReviews: totalReviews, undoneReviews: undoneReviews, enrolledSenses: enrolledSenses,
            activeSenses: activeSenses, exercises: exercises)
    }

    /// These are Nibomo's exact half-open due ranges, including overdue work in Today.
    /// Boundaries come from Calendar day addition, so a DST day is never assumed to be 24h.
    private static func bucket(dueMillis: Int64?, boundaries: ReviewScheduleBucketBoundaries) -> ReviewScheduleBucketKey {
        guard let dueMillis else { return .new }
        switch dueMillis {
        case ..<boundaries.startOfTomorrowMillis: return .today
        case ..<boundaries.startOfDay8Millis: return .days1To7
        case ..<boundaries.startOfDay31Millis: return .days8To30
        case ..<boundaries.startOfDay91Millis: return .days31To90
        case ..<boundaries.startOfDay361Millis: return .days91To360
        case ..<boundaries.startOfDay721Millis: return .years1To2
        default: return .later
        }
    }
}
