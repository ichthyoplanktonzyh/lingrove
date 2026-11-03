// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W4_PROGRESS_REUSE_MAP.md.
import Foundation
import LingroveNotebookEngine

/// The query already validates the statistical series. This pure presentation adapter extracts
/// Nibomo's five-week streak calendar while using the exact frozen read calendar for every date.
/// The IO actor calls it before returning, keeping date expansion off the main actor.
nonisolated enum NotebookProgressPresentationFactory {
    static func make(_ snapshot: NotebookProgressSnapshot) throws -> NotebookProgressContent {
        let calendar = snapshot.calendar
        let states = Dictionary(uniqueKeysWithValues: snapshot.streakDays.map { ($0.date, $0.state) })
        let chartDays = try snapshot.dailyReviews.map { day in
            try Task.checkCancellation()
            return NotebookProgressChartDay(date: try progressDate(localDate: day.date, calendar: calendar),
                localDate: day.date, reviewCount: day.reviewCount, streakState: states[day.date] ?? .missed,
                againCount: day.againCount, hardCount: day.hardCount, goodCount: day.goodCount,
                easyCount: day.easyCount, isToday: day.date == snapshot.range.to)
        }
        return try .init(snapshot: snapshot, chartDays: chartDays,
            streakWeeks: makeProgressStreakWeeks(chartDays: chartDays, todayLocalDate: snapshot.range.to,
                calendar: calendar))
    }

    private static func makeProgressStreakWeeks(
        chartDays: [NotebookProgressChartDay], todayLocalDate: String, calendar: Calendar
    ) throws -> [NotebookProgressCalendarWeek] {
        let today = try progressDate(localDate: todayLocalDate, calendar: calendar)
        guard let currentWeekInterval = calendar.dateInterval(of: .weekOfYear, for: today) else {
            throw ProgressPresentationError.invalidLocalDate(todayLocalDate)
        }
        let currentWeekStart = calendar.startOfDay(for: currentWeekInterval.start)
        let streakDayCount = progressDaysPerWeek * 5
        guard let streakStart = calendar.date(byAdding: .day,
            value: -(streakDayCount - progressDaysPerWeek), to: currentWeekStart) else {
            throw ProgressPresentationError.invalidLocalDate(todayLocalDate)
        }
        let chartDaysByLocalDate = Dictionary(uniqueKeysWithValues: chartDays.map { ($0.localDate, $0) })
        let streakDays = try (0..<streakDayCount).map { offset in
            guard let rawDate = calendar.date(byAdding: .day, value: offset, to: streakStart) else {
                throw ProgressPresentationError.invalidLocalDate(todayLocalDate)
            }
            let date = calendar.startOfDay(for: rawDate)
            let localDate = progressLocalDateString(date: date, calendar: calendar)
            let isFuturePlaceholder = date > today
            let reviewCount: Int
            let streakState: ProgressStreakDayState
            if !isFuturePlaceholder {
                guard let chartDay = chartDaysByLocalDate[localDate] else {
                    throw ProgressPresentationError.missingStreakDay(localDate)
                }
                reviewCount = chartDay.reviewCount
                streakState = chartDay.streakState
            } else {
                reviewCount = 0
                streakState = .pending
            }
            return NotebookProgressCalendarDay(date: date, localDate: localDate, reviewCount: reviewCount,
                streakState: streakState, isToday: localDate == todayLocalDate,
                isFuturePlaceholder: isFuturePlaceholder, dayNumber: calendar.component(.day, from: date))
        }
        return stride(from: 0, to: streakDays.count, by: progressDaysPerWeek).map { startIndex in
            NotebookProgressCalendarWeek(days: Array(streakDays[startIndex..<startIndex + progressDaysPerWeek]))
        }
    }
}

nonisolated func progressChartUpperBound(maximumReviewCount: Int) -> Int {
    guard maximumReviewCount > 0 else { return 1 }
    return max(1, Int(ceil(Double(maximumReviewCount) * 1.1)))
}
