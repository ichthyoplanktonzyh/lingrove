import Foundation

/// The preparation sheet owns this original editable projection for its one draft lifetime.
/// It deliberately excludes preview/navigation state: moving between front and back, selecting
/// text or showing a preview must not make Cancel destructive. Persistence remains the session's
/// responsibility; this value only decides whether the native sheet asks before discarding edits.
nonisolated struct BuiltInReviewDraftPresentationSnapshot: Equatable {
    let exampleID: UUID?
    let front: String
    let back: String
    let tags: [String]

    init(_ draft: BuiltInReviewDraft) {
        exampleID = draft.exampleID
        front = draft.front
        back = draft.back
        tags = draft.tags
    }
}
