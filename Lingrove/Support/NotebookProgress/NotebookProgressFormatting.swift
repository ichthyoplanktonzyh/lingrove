// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W4_PROGRESS_REUSE_MAP.md.
/// Extracted personal chart formatting and palette. Notebook copy uses its own Mac catalog;
/// network/leaderboard formatting and the mobile store are outside this module.
import Foundation
import SwiftUI
import LingroveNotebookEngine

/// The upstream AccentColor asset is orange. A destination-local value prevents the Mac's
/// system accent from changing the extracted calendar while leaving the corpus UI untouched.
nonisolated let notebookProgressAccent = Color(red: 1, green: 0.404, blue: 0.098)

nonisolated let progressReviewRatingChartOrder: [ReviewRating] = [.again, .hard, .good, .easy]

nonisolated func progressReviewChartPageDateRange(
    page: NotebookProgressReviewChartPage,
    calendar: Calendar
) -> String {
    let formatter = DateIntervalFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: page.startDate, to: page.endDate)
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
        return Color(red: 0xD7 / 255, green: 0x26 / 255, blue: 0x3D / 255)
    case .hard:
        return Color(red: 0xE6 / 255, green: 0x9F / 255, blue: 0x00 / 255)
    case .good:
        return Color(red: 0x2B / 255, green: 0xB6 / 255, blue: 0x73 / 255)
    case .easy:
        return Color(red: 0x3F / 255, green: 0x7C / 255, blue: 0xC8 / 255)
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

// Palette decisions: docs/progress-pie-palette.md. Keep the hex values in sync with
// apps/android/feature/progress/src/main/java/com/flashcardsopensourceapp/feature/progress/sections/NotebookProgressReviewScheduleSection.kt::reviewScheduleBucketColors
// and apps/web/src/screens/progress/reviewSchedule/progressReviewScheduleModel.ts::reviewScheduleBucketColors.
nonisolated func progressReviewScheduleBucketColor(key: ReviewScheduleBucketKey) -> Color {
    switch key {
    case .new:
        return Color(red: 0xF4 / 255, green: 0xC4 / 255, blue: 0x30 / 255)
    case .today:
        return Color(red: 0xD7 / 255, green: 0x26 / 255, blue: 0x3D / 255)
    case .days1To7:
        return Color(red: 0x1F / 255, green: 0xB5 / 255, blue: 0xC1 / 255)
    case .days8To30:
        return Color(red: 0x8E / 255, green: 0x5B / 255, blue: 0xD9 / 255)
    case .days31To90:
        return Color(red: 0x2B / 255, green: 0xB6 / 255, blue: 0x73 / 255)
    case .days91To360:
        return Color(red: 0xE6 / 255, green: 0x9F / 255, blue: 0x00 / 255)
    case .years1To2:
        return Color(red: 0x3F / 255, green: 0x7C / 255, blue: 0xC8 / 255)
    case .later:
        return Color(red: 0x7A / 255, green: 0x80 / 255, blue: 0x88 / 255)
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
