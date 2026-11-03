// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W4_PROGRESS_REUSE_MAP.md.
/// Immutable chart and calendar values extracted from Nibomo. The read actor builds them;
/// SwiftUI owns only selection state and never aggregates database rows on the main actor.
import Foundation
import LingroveNotebookEngine

/// The read actor returns data and its derived display values together, so the view cannot mix
/// a newly read summary with an older calendar or forecast. No service reference crosses back.
nonisolated struct NotebookProgressContent: Sendable {
    let snapshot: NotebookProgressSnapshot
    let chartDays: [NotebookProgressChartDay]
    let streakWeeks: [NotebookProgressCalendarWeek]
}

nonisolated struct NotebookProgressCalendarDay: Hashable, Identifiable, Sendable {
    let date: Date
    let localDate: String
    let reviewCount: Int
    let streakState: ProgressStreakDayState
    let isToday: Bool
    let isFuturePlaceholder: Bool
    let dayNumber: Int

    var id: String {
        self.localDate
    }
}

nonisolated struct NotebookProgressCalendarWeek: Hashable, Identifiable, Sendable {
    let days: [NotebookProgressCalendarDay]

    var id: String {
        guard let firstDay = self.days.first else {
            preconditionFailure("Progress calendar week must contain at least one day")
        }

        return firstDay.localDate
    }
}

nonisolated struct NotebookProgressChartDay: Hashable, Identifiable, Sendable {
    let date: Date
    let localDate: String
    let reviewCount: Int
    let streakState: ProgressStreakDayState
    let againCount: Int
    let hardCount: Int
    let goodCount: Int
    let easyCount: Int
    let isToday: Bool

    var id: String {
        self.localDate
    }
}
