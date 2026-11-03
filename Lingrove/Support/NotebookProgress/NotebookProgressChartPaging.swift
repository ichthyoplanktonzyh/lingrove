// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W4_PROGRESS_REUSE_MAP.md.
/// Pure extracted week paging; Calendar civil-day addition preserves DST and first-weekday rules.
import Foundation
import LingroveNotebookEngine

nonisolated struct NotebookProgressReviewChartPage: Identifiable {
    let days: [NotebookProgressChartDay]
    let startLocalDate: String
    let startDate: Date
    let endDate: Date

    init(days: [NotebookProgressChartDay]) {
        guard let firstDay = days.first, let lastDay = days.last else {
            preconditionFailure("Progress review chart page must contain at least one day")
        }

        self.days = days
        self.startLocalDate = firstDay.localDate
        self.startDate = firstDay.date
        self.endDate = lastDay.date
    }

    var id: String {
        self.startLocalDate
    }

    var xAxisValues: [String] {
        self.days.map(\.localDate)
    }

    nonisolated func day(localDate: String) -> NotebookProgressChartDay? {
        self.days.first(where: { day in
            day.localDate == localDate
        })
    }
}

nonisolated struct NotebookProgressChartResetToken: Equatable {
    let selectionResetKey: String
    let chartDays: [NotebookProgressChartDay]
}

nonisolated func makeNotebookProgressReviewChartPages(
    chartDays: [NotebookProgressChartDay],
    calendar: Calendar,
    today: Date?
) -> [NotebookProgressReviewChartPage] {
    guard chartDays.isEmpty == false else {
        return []
    }

    var pages: [NotebookProgressReviewChartPage] = []
    var currentPageDays: [NotebookProgressChartDay] = []
    var currentWeekStart: Date?

    for day in chartDays {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: day.date) else {
            preconditionFailure("Expected a week interval for progress review chart day")
        }

        let weekStart = calendar.startOfDay(for: weekInterval.start)
        if let activeWeekStart = currentWeekStart, activeWeekStart != weekStart {
            pages.append(
                NotebookProgressReviewChartPage(
                    days: padReviewChartPageToFullWeek(
                        currentPageDays: currentPageDays,
                        weekStart: activeWeekStart,
                        calendar: calendar,
                        today: today
                    )
                )
            )
            currentPageDays = [day]
            currentWeekStart = weekStart
            continue
        }

        currentPageDays.append(day)
        currentWeekStart = weekStart
    }

    if let weekStart = currentWeekStart, currentPageDays.isEmpty == false {
        pages.append(
            NotebookProgressReviewChartPage(
                days: padReviewChartPageToFullWeek(
                    currentPageDays: currentPageDays,
                    weekStart: weekStart,
                    calendar: calendar,
                    today: today
                )
            )
        )
    }

    return pages
}

nonisolated private func padReviewChartPageToFullWeek(
    currentPageDays: [NotebookProgressChartDay],
    weekStart: Date,
    calendar: Calendar,
    today: Date?
) -> [NotebookProgressChartDay] {
    let existingByLocalDate = Dictionary(uniqueKeysWithValues: currentPageDays.map { day in
        (day.localDate, day)
    })

    return (0 ..< progressDaysPerWeek).map { offset in
        guard let rawDate = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
            preconditionFailure("Failed to advance week start by \(offset) days")
        }

        let date = calendar.startOfDay(for: rawDate)
        let localDate = progressLocalDateString(date: date, calendar: calendar)

        if let existing = existingByLocalDate[localDate] {
            return existing
        }

        let isToday: Bool
        if let today {
            isToday = calendar.isDate(date, inSameDayAs: today)
        } else {
            isToday = false
        }

        return NotebookProgressChartDay(
            date: date,
            localDate: localDate,
            reviewCount: 0,
            streakState: isToday ? .pending : .missed,
            againCount: 0,
            hardCount: 0,
            goodCount: 0,
            easyCount: 0,
            isToday: isToday
        )
    }
}
