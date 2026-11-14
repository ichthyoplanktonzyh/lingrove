import Foundation
import LingroveNotebook

/// A writer-owned presentation receipt pins both sides of the review clock. A host may patch
/// an already-complete review value only when it owns exactly this base and the final clocks
/// still match. Concurrent ratings/enrollment, raw writes or lost receipts require a full read.
public nonisolated struct NotebookReviewEdit: Sendable {
    public let version: LingroveNotebookVersion
    public let corpus: NotebookChangeToken
    public let baseReview: NotebookChangeToken
    public let review: NotebookChangeToken
    public let style: ReviewNoteType?
    public let selection: Selection?
    public let hasPendingSync: Bool

    /// Distinct from a complete snapshot: only these source groups and their owned rows were
    /// read. The source IDs include historical aliases so merges cannot leave stale groups.
    public struct Selection: Sendable {
        public let senseIDs: Set<UUID>
        public let groups: [UUID: LingroveNotebookReviewGroup]
        public let links: [LingroveNotebookCardLink]
        public let noteCards: [String: NotebookReviewNoteCard]
    }
}

extension LingroveNotebookEngine {
    func reviewEdit(scope: LingroveNotebookSnapshot, base: NotebookChangeToken,
                    style: ReviewNoteType? = nil, senseIDs: Set<UUID>? = nil) throws -> NotebookReviewEdit {
        let stamp = try core.notebookChangeStamp()
        let selected = try senseIDs.map { try loadLingroveNotebookReviewSnapshotInTransaction(current: scope, selecting: $0, pendingOverride: true) }
        // A successful CAS edit increments a Note/type revision. Mark this local edit pending;
        // normal ACK reconciliation computes the complete digest. UI receipt construction must
        // not decode every unrelated Note/type just to hash that same new state again.
        return .init(version: .init(scope), corpus: stamp.corpus, baseReview: base, review: stamp.review, style: style,
            selection: selected.flatMap { value in senseIDs.map { .init(senseIDs: $0, groups: value.groups, links: value.links, noteCards: value.noteCards) } },
            hasPendingSync: true)
    }
}

extension NotebookReviewEdit {
    /// Pure presentation patching has no persistence authority. The host must first verify
    /// this receipt's base/final clocks on its serialized connection; nil requests a full read.
    public func applying(to previous: LingroveNotebookReviewSnapshot) -> LingroveNotebookReviewSnapshot? {
        guard previous.workspaceId == version.workspaceId, previous.notebookId == version.notebookId,
              previous.notebookRevision == version.revision else { return nil }
        var groups = previous.groups, links = previous.links, models = previous.noteCards
        if let style {
            models = models.mapValues { model in
                model.noteType.id == style.id ? .init(note: model.note, noteType: style, templateID: model.templateID) : model
            }
        } else if let selection {
            let ids = selection.senseIDs
            let removed = Set(groups.values.filter {
                ids.contains($0.selection.senseID) || $0.enrollments.contains { ids.contains($0.senseId) }
            }.flatMap { $0.cards.map(\.cardId) })
            groups = groups.filter { !ids.contains($0.key) && !$0.value.enrollments.contains { ids.contains($0.senseId) } }
            groups.merge(selection.groups) { _, new in new }
            links.removeAll { ids.contains($0.source.senseId) || removed.contains($0.cardId) }
            links += selection.links
            links.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
            models = models.filter { !ids.contains($0.value.note.senseID) && !removed.contains($0.key) }
            models.merge(selection.noteCards) { _, new in new }
        } else { return nil }
        return .init(workspaceId: previous.workspaceId, notebookId: previous.notebookId,
            notebookRevision: previous.notebookRevision, groups: groups, links: links,
            hasPendingSync: hasPendingSync, noteCards: models)
    }
}
