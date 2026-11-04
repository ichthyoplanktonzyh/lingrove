import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// Navigation is window-local. It never means that a sense has been enrolled, answered or
/// paused; those choices have their own explicit, scoped database commands.
nonisolated enum BuiltInReviewRoute: Hashable, Sendable {
    case overview
    case content
    case adding
    case sense(VocabularySelection)
    case practice
}

/// A displayed question pins the exact Card and source state the user saw. Every later reveal,
/// rating or edit uses this value, even if the canonical queue changes in the background.
nonisolated struct BuiltInReviewCardContext: Sendable {
    let snapshot: LingroveNotebookSnapshot
    let card: Card
    let link: LingroveNotebookCardLink
    let group: LingroveNotebookReviewGroup
    let schedulerSettings: WorkspaceSchedulerSettings
    let action: NotebookBuiltInReviewAction
}

/// The window owns only transient practice presentation. Persisted Card scheduling supplies
/// the next queue on reopen; `answered` is clearly a count of this open session, not a second
/// durable progress ledger. The phase enum prevents rating an unrevealed question.
nonisolated struct BuiltInReviewPractice: Sendable {
    enum Phase: Sendable {
        case question(BuiltInReviewCardContext)
        case answer(BuiltInReviewCardContext)
        case finished

        var context: BuiltInReviewCardContext? {
            switch self {
            case let .question(value), let .answer(value): value
            case .finished: nil
            }
        }
    }

    let selection: VocabularySelection?
    var initialDueCount = 0
    var answered = 0
    var phase: Phase = .finished
}

/// A retained undo affordance is bound to the original scope and causal rating. It can be
/// reconstructed from SQLite after reopening, while old window callbacks keep their old fence.
nonisolated struct BuiltInReviewUndoAction: Sendable {
    let action: NotebookBuiltInReviewAction
    let identity: NotebookBuiltInReviewUndo
}

/// Image bytes cross from short-lived IO to the native view; no URLSession or remote-image
/// view is involved. Identity includes the managed asset ID authorized in the original scope.
nonisolated struct BuiltInReviewSavedImage: Identifiable, Sendable {
    let id: String
    let data: Data
}

/// Validated audio is borrowed by the practice face, just like images. The session's existing
/// speech owner plays these bytes directly, without regeneration or another provider request.
nonisolated struct BuiltInReviewSavedAudio: Identifiable, Sendable {
    let id: String
    let kind: ReviewAudioKind
    let data: Data
    let fileExtension: String
}

/// The session retains this window-only browser state while detail views are replaced. It
/// carries no write authority; closing or changing account clears searches and selections.
nonisolated struct BuiltInReviewBrowsing {
    var filter: BuiltInReviewContentFilter = .active
    var search = ""
    var addingSearch = ""
    var selectedSenseIDs = Set<UUID>()
    // Direct links from the corpus have no browser origin and open a standalone detail.
    var detailOrigin: BuiltInReviewRoute?
}

/// Participation and material health are independent facts. Attention is a cross-status view,
/// so a paused item with missing material can be found without losing its participation label.
nonisolated enum BuiltInReviewContentFilter: String, CaseIterable {
    case active, paused, withdrawn, attention
    var titleKey: String { self == .attention ? "filter.attention" : "status." + rawValue }
}
