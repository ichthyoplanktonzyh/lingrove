import Foundation
import LingroveNotebook

/// Notebook writers invoke this adapter inside their existing transaction, after replacing
/// source rows. It projects only faces/tags; the Card's FSRS fields and append-only events are
/// never touched. Missing evidence is persisted as queue admission state, not guessed at read.
public struct LingroveNotebookReviewMaterialStore {
    public let core: DatabaseCore

    public func refreshInTransaction(_ snapshot: LingroveNotebookSnapshot, senseIDs: Set<UUID>? = nil,
                                     entries: [VocabularyEntry]? = nil) throws {
        try refreshInTransaction(version: .init(snapshot), entries: entries ?? snapshot.document.entries, senseIDs: senseIDs)
    }

    /// Full and local notebook writers share material projection and history retention.
    /// The local writer supplies every live/historical affected source and its complete entry.
    func refreshInTransaction(version: LingroveNotebookVersion, entries: [VocabularyEntry], senseIDs: Set<UUID>? = nil) throws {
        guard senseIDs?.isEmpty != true else { return }
        try ReviewNoteStore(core: core).refreshInTransaction(version: version, entries: entries, senseIDs: senseIDs)
    }

    /// The certified local writer supplies only IDs it just retired, including merged aliases.
    /// No live source remains for these IDs, so sourceMissing/retained is the complete refresh:
    /// no face rendering, new template members, Card writes or event changes are necessary.
    /// This adapter borrows that writer's transaction; it never accepts arbitrary UI drafts or
    /// constructs a partial snapshot. Other sources and other notebook lifetimes stay untouched.
    func retireSourcesInTransaction(version: LingroveNotebookVersion, senseIDs: Set<UUID>) throws {
        guard !senseIDs.isEmpty else { return }
        let notes = ReviewNoteStore(core: core)
        let selectedNotes = try notes.notes(version: version, senseIDs: senseIDs)
        let members = try notes.memberships(workspace: version.workspaceId, noteIDs: Set(selectedNotes.map(\.id)))
        // Validate only definitions belonging to the affected members. A malformed/missing
        // type must still fail atomically; unrelated Notes/types do not enter this command.
        let models = try notes.cardModels(version: version, cardIDs: Set(members.map(\.cardID)))
        for member in members {
            try Task.checkCancellation()
            guard let model = models[member.cardID] else { throw VocabularyError.invalidArchive }
            try notes.refreshCard(member.cardID, model: model, version: version, source: nil)
        }
    }

    /// The full renderer and certified retirement share the same derived admission write.
    /// Status never mutates the Card, enrollment, Note definition or append-only history.
    func setStatus(_ status: String, cardID: String, workspace: String) throws {
        try core.execute(sql: """
            INSERT INTO notebook_review_material_state(workspace_id,card_id,status) VALUES(?,?,?)
            ON CONFLICT(workspace_id,card_id) DO UPDATE SET status=excluded.status
            """, values: [.text(workspace), .text(cardID), .text(status)])
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
