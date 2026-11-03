// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_PROGRESS_UI_REUSE.md.
/// Extracted personal chart formatting and palette. Notebook copy uses its own Mac catalog;
/// network/leaderboard formatting and the mobile store are outside this module.
import Foundation
import SwiftUI
import LingroveNotebookEngine

/// Calendar emphasis follows Lingrove's existing accent. Chart categories below retain their
/// own semantic palette, so changing the accent never erases rating or scheduling distinctions.
nonisolated let notebookProgressAccent = Color.accentColor

nonisolated let progressReviewRatingChartOrder: [ReviewRating] = [.again, .hard, .good, .easy]

nonisolated func progressReviewChartPageDateRange(
    page: NotebookProgressReviewChartPage,
    calendar: Calendar
) -> String {
    progressDateRangeLabel(from: page.startDate, to: page.endDate, calendar: calendar)
}

/// Calendar and chart captions share one civil-date formatter, so their visible range uses
/// the same locale and frozen query timezone rather than the machine's current timezone.
nonisolated func progressDateRangeLabel(from start: Date, to end: Date, calendar: Calendar) -> String {
    let formatter = DateIntervalFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: start, to: end)
}

nonisolated func progressReviewChartDateLabel(date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

nonisolated func progressWeekdayLabel(date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("EEEEE")
    return formatter.string(from: date)
}

nonisolated func progressCompleteDateLabel(date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .full
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

nonisolated func progressReviewChartDayLabel(date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "d"
    return formatter.string(from: date)
}

nonisolated func progressReviewRatingTitle(rating: ReviewRating) -> String {
    NotebookProgressCopy.rating(rating)
}

nonisolated func progressReviewRatingColor(rating: ReviewRating) -> Color {
    switch rating {
    case .again:
        return .red
    case .hard:
        return .orange
    case .good:
        return .green
    case .easy:
        return .blue
    }
}

nonisolated func progressReviewRatingCount(day: NotebookProgressChartDay, rating: ReviewRating) -> Int {
    switch rating {
    case .again:
        return day.againCount
    case .hard:
        return day.hardCount
    case .good:
        return day.goodCount
    case .easy:
        return day.easyCount
    }
}

nonisolated func progressReviewRatingPercentage(
    count: Int,
    totalReviewCount: Int
) -> String {
    guard totalReviewCount > 0 else {
        return Double(0).formatted(.percent.precision(.fractionLength(0)))
    }

    let ratio = Double(count) / Double(totalReviewCount)
    return ratio.formatted(.percent.precision(.fractionLength(0)))
}

nonisolated func progressReviewScheduleBucketTitle(key: ReviewScheduleBucketKey) -> String {
    switch key {
    case .new:
        return String(
            localized: "progress.screen.review_schedule.bucket.new",
            defaultValue: "New",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for cards without a due date"
        )
    case .today:
        return String(
            localized: "progress.screen.review_schedule.bucket.today",
            defaultValue: "Today",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for overdue and due-today cards"
        )
    case .days1To7:
        return String(
            localized: "progress.screen.review_schedule.bucket.days_1_to_7",
            defaultValue: "1-7 days",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for cards due in one to seven days"
        )
    case .days8To30:
        return String(
            localized: "progress.screen.review_schedule.bucket.days_8_to_30",
            defaultValue: "8-30 days",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for cards due in eight to thirty days"
        )
    case .days31To90:
        return String(
            localized: "progress.screen.review_schedule.bucket.days_31_to_90",
            defaultValue: "31-90 days",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for cards due in thirty-one to ninety days"
        )
    case .days91To360:
        return String(
            localized: "progress.screen.review_schedule.bucket.days_91_to_360",
            defaultValue: "91-360 days",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for cards due in ninety-one to three hundred sixty days"
        )
    case .years1To2:
        return String(
            localized: "progress.screen.review_schedule.bucket.years_1_to_2",
            defaultValue: "1-2 years",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for cards due in one to two years"
        )
    case .later:
        return String(
            localized: "progress.screen.review_schedule.bucket.later",
            defaultValue: "Later",
            table: "NotebookProgress",
            comment: "Review schedule bucket label for cards due later than two years"
        )
    }
}

// These eight category colors remain independent of accent. Native semantic variants adapt
// to Aqua/darkAqua, and every wedge is also named and counted in the selectable legend.
nonisolated func progressReviewScheduleBucketColor(key: ReviewScheduleBucketKey) -> Color {
    switch key {
    case .new:
        return .yellow
    case .today:
        return .red
    case .days1To7:
        return .cyan
    case .days8To30:
        return .purple
    case .days31To90:
        return .green
    case .days91To360:
        return .orange
    case .years1To2:
        return .blue
    case .later:
        return .gray
    }
}

nonisolated func progressReviewScheduleBucketPercentage(
    bucket: ReviewScheduleBucket,
    totalCards: Int
) -> String {
    guard totalCards > 0 else {
        return Double(0).formatted(.percent.precision(.fractionLength(0)))
    }

    let ratio = Double(bucket.count) / Double(totalCards)
    return ratio.formatted(.percent.precision(.fractionLength(0)))
}

nonisolated func progressReviewScheduleChartAccessibilityLabel() -> String {
    String(
        localized: "progress.screen.review_schedule.section_title",
        defaultValue: "Review schedule",
        table: "NotebookProgress",
        comment: "Progress review schedule section title"
    )
}

nonisolated func progressReviewScheduleBucketAccessibilityValue(
    bucket: ReviewScheduleBucket,
    totalCards: Int
) -> String {
    let localizedFormat = String(
        localized: "progress.screen.review_schedule.bucket.accessibility_value",
        defaultValue: "%lld exercises, %@",
        table: "NotebookProgress",
        comment: "Accessibility value for a review schedule bucket with card count and percentage"
    )
    return String(
        format: localizedFormat,
        locale: Locale.current,
        Int64(bucket.count),
        progressReviewScheduleBucketPercentage(bucket: bucket, totalCards: totalCards)
    )
}

nonisolated func progressReviewScheduleAccessibilitySummary(schedule: UserReviewSchedule) -> String {
    schedule.buckets.map { bucket in
        let title = progressReviewScheduleBucketTitle(key: bucket.key)
        let detail = progressReviewScheduleBucketAccessibilityValue(bucket: bucket, totalCards: schedule.totalCards)
        return "\(title): \(detail)"
    }
    .joined(separator: ", ")
}
