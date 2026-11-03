import LingroveNotebook
import Foundation
import LingroveNotebookEngine

/// Landing-state policy consumes immutable repository facts. It deliberately has no finished
/// case: completion belongs only to a round that accepted a rating, never to an empty queue.
nonisolated enum BuiltInReviewOverviewState: Equatable {
    case noCorpus, noSelection, due, paused, unavailable, scheduled(Date?)

    init(content: NotebookBuiltInReviewSnapshot) {
        if !content.queue.isEmpty { self = .due; return }
        let groups = Array(content.review.groups.values)
        if groups.contains(where: { $0.status == .active && $0.hasUnavailableMaterial }) { self = .unavailable; return }
        if groups.contains(where: { $0.status == .active && !$0.cards.isEmpty }) {
            let dates = groups.filter { $0.status == .active && !$0.hasUnavailableMaterial }.flatMap(\.cards)
                .compactMap { $0.dueAt.flatMap { parseIsoTimestamp(value: $0) } }
            self = .scheduled(dates.min()); return
        }
        if !groups.isEmpty { self = .paused; return }
        self = content.scope.document.collectedEntries.isEmpty ? .noCorpus : .noSelection
    }

    var titleKey: String {
        switch self {
        case .noCorpus: "state.noCorpus"
        case .noSelection: "state.noSelection"
        case .due: "today.ready"
        case .paused: "today.paused"
        case .unavailable: "today.unavailable"
        case .scheduled: "today.scheduled"
        }
    }
    var actionKey: String {
        switch self {
        case .noCorpus: "action.browseCorpus"
        case .noSelection: "action.addContent"
        case .due: "action.start"
        case .paused, .scheduled: "action.manage"
        case .unavailable: "action.fixMaterial"
        }
    }
    var symbol: String {
        switch self {
        case .due: "rectangle.on.rectangle"
        case .unavailable: "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .scheduled: "calendar"
        default: "tray"
        }
    }
    var nextDue: Date? { if case let .scheduled(date) = self { date } else { nil } }
}
