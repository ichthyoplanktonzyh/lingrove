// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W4_PROGRESS_REUSE_MAP.md.
import SwiftUI
import LingroveNotebookEngine

private let progressStreakCalendarColumnSpacing: CGFloat = 10
private let progressStreakCalendarHeaderSpacing: CGFloat = 10
private let progressStreakCalendarWeekSpacing: CGFloat = 12

/// Extracted five-week personal streak calendar. The destination owns its immutable summary;
/// the badge retains Nibomo's reviewed-today treatment, without a server freeze-bank feature.
struct NotebookProgressStreakSection: View {
    let summary: ProgressSummary
    let weeks: [NotebookProgressCalendarWeek]
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NotebookProgressCopy.text("progress.screen.streak.section_title"))
                .font(.headline)
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: summary.hasReviewedToday ? "flame.fill" : "flame")
                        .foregroundStyle(summary.hasReviewedToday ? notebookProgressAccent : .gray)
                    Text(summary.currentStreakDays > 99 ? "99+" : summary.currentStreakDays.formatted())
                        .monospacedDigit()
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .frame(minHeight: 34)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder(summary.hasReviewedToday ? notebookProgressAccent.opacity(0.55) : .gray.opacity(0.35)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(NotebookProgressCopy.format(summary.hasReviewedToday ? "streak.reviewed_today" : "streak.pending_today",
                    summary.currentStreakDays.formatted()))
                Spacer(minLength: 0)
                Text(NotebookProgressCopy.format("streak.longest", summary.longestStreakDays.formatted()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NotebookProgressStreakCalendarGrid(headerDays: weeks.first?.days ?? [], weeks: weeks, calendar: calendar)
        }
        .padding(.vertical, 4)
    }
}

private struct NotebookProgressStreakCalendarGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var dayDiameter: CGFloat = 38

    let headerDays: [NotebookProgressCalendarDay]
    let weeks: [NotebookProgressCalendarWeek]
    let calendar: Calendar

    var body: some View {
        if self.dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal) {
                self.calendarContent
                    .frame(minWidth: self.dayDiameter * 7 + progressStreakCalendarColumnSpacing * 6)
                    .padding(.vertical, 2)
            }
        } else {
            self.calendarContent
        }
    }

    private var calendarContent: some View {
        VStack(alignment: .leading, spacing: progressStreakCalendarHeaderSpacing) {
            HStack(spacing: progressStreakCalendarColumnSpacing) {
                ForEach(self.headerDays) { day in
                    Text(progressWeekdayLabel(date: day.date, calendar: self.calendar))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: progressStreakCalendarWeekSpacing) {
                ForEach(self.weeks) { week in
                    NotebookProgressStreakWeekRow(week: week, calendar: self.calendar)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotebookProgressStreakWeekRow: View {
    let week: NotebookProgressCalendarWeek
    let calendar: Calendar

    var body: some View {
        HStack(spacing: progressStreakCalendarColumnSpacing) {
            ForEach(self.week.days) { day in
                NotebookProgressStreakDayCell(day: day, calendar: self.calendar)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotebookProgressStreakDayCell: View {
    @ScaledMetric(relativeTo: .footnote) private var dayDiameter: CGFloat = 38

    let day: NotebookProgressCalendarDay
    let calendar: Calendar

    var body: some View {
        ZStack {
            Circle()
                .fill(self.backgroundColor)

            Circle()
                .stroke(self.borderColor, lineWidth: self.borderLineWidth)

            if self.isActiveFlameDay {
                Image(systemName: "flame.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(self.foregroundColor)
            } else {
                Text(self.day.dayNumber.formatted())
                    .font(.footnote.weight(self.day.isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(self.foregroundColor)
            }
        }
        .frame(maxWidth: self.dayDiameter)
        .frame(height: self.dayDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var backgroundColor: Color {
        if self.day.isFuturePlaceholder {
            return Color.clear
        }

        if self.isActiveFlameDay {
            return notebookProgressAccent
        }

        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if self.day.isFuturePlaceholder {
            return Color(nsColor: .separatorColor).opacity(0.18)
        }

        if self.isActiveFlameDay {
            return notebookProgressAccent
        }

        if self.day.isToday {
            return notebookProgressAccent
        }

        return Color(nsColor: .separatorColor).opacity(0.35)
    }

    private var foregroundColor: Color {
        if self.day.isFuturePlaceholder {
            return .secondary
        }

        if self.isActiveFlameDay {
            return .white
        }

        if self.day.isToday {
            return notebookProgressAccent
        }

        return .primary
    }

    private var isActiveFlameDay: Bool {
        self.day.streakState == .reviewed
    }

    private var borderLineWidth: CGFloat {
        self.day.isToday && self.isActiveFlameDay == false ? 2 : 1
    }

    private var accessibilityLabel: String {
        if self.day.isFuturePlaceholder {
            let dateTitle = progressCompleteDateLabel(date: self.day.date, calendar: self.calendar)
            let futureTitle = String(
                localized: "progress.screen.streak.future_day.accessibility",
                defaultValue: "Future day",
                table: "NotebookProgress",
                comment: "Accessibility label component for a future streak calendar day"
            )

            return [dateTitle, futureTitle].joined(separator: ", ")
        }

        let dateTitle = progressCompleteDateLabel(date: self.day.date, calendar: self.calendar)
        let todayTitle = String(
            localized: "progress.screen.today",
            defaultValue: "Today",
            table: "NotebookProgress",
            comment: "Progress today label"
        )
        let reviewsTitle = String.localizedStringWithFormat(
            String(
                localized: "progress.screen.reviews.accessibility",
                defaultValue: "%lld reviews",
                table: "NotebookProgress",
                comment: "Accessibility label suffix for daily review counts"
            ),
            Int64(self.day.reviewCount)
        )
        let streakStateTitle: String?
        switch self.day.streakState {
        case .reviewed:
            streakStateTitle = nil
        case .frozen:
            streakStateTitle = nil
        case .missed:
            streakStateTitle = nil
        case .pending:
            streakStateTitle = nil
        }

        if self.day.isToday {
            return [dateTitle, todayTitle, streakStateTitle, reviewsTitle]
                .compactMap { component in component }
                .joined(separator: ", ")
        }

        return [dateTitle, streakStateTitle, reviewsTitle]
            .compactMap { component in component }
            .joined(separator: ", ")
    }
}
