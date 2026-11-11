import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

/// Only the serialized writer creates this plan from its checked cache and a validated next
/// state. One value keeps SQL changes, material impact, UI receipts and post-commit cache in
/// agreement. The plan lives for one transaction; failure discards it through Core rollback.
struct LingroveNotebookSavePlan {
    let state: VocabularyEntrySaveState
    let rows: VocabularyEntryRowChange
    let entryIDs: Set<UUID>
    let reviewSenseIDs: Set<UUID>?
    let requiresEntryReload: Bool

    init(previous: LingroveNotebookSaveCache, state: VocabularyEntrySaveState,
         rows: VocabularyEntryRowChange, knownEntryIDs: Set<UUID>? = nil) throws {
        self.state = state; self.rows = rows
        if let knownEntryIDs {
            entryIDs = knownEntryIDs
            reviewSenseIDs = Self.reviewIDs(entries: previous.state.entries, ids: knownEntryIDs)
                .union(Self.reviewIDs(entries: state.entries, ids: knownEntryIDs))
            requiresEntryReload = false
            return
        }
        // Repositioned rows now contain only authored/history/template sequences. Membership
        // rows never compact, so their unchanged survivors need neither receipts nor materials.
        let keys = Set((rows.changed + rows.removed + rows.repositioned).map(\.key))
        let before = try previous.projection.materialRoots(for: keys)
        let after = try rows.projection.materialRoots(for: keys)
        var ids = before.entryIDs.union(after.entryIDs)
        var senses = before.senseIDs.union(after.senseIDs)
        // New evidence is already covered by new claims. Only pre-existing evidence changes
        // can affect other saved interpretations, so ordinary append avoids a second scan.
        if !before.sourceIDs.isEmpty || !before.occurrenceIDs.isEmpty {
            var occurrences = before.occurrenceIDs
            for document in [previous.state.document, state.document] {
                for occurrence in document.occurrences where before.sourceIDs.contains(occurrence.sourceID) {
                    occurrences.insert(occurrence.id)
                }
            }
            for document in [previous.state.document, state.document] {
                for claim in document.interpretations where occurrences.contains(claim.occurrenceID) {
                    if let id = claim.senseID { senses.insert(id) }
                }
            }
        }
        for entry in previous.state.entries + state.entries where entry.senses.contains(where: {
            senses.contains($0.id) || !$0.mergedFrom.allSatisfy { !senses.contains($0) }
        }) { ids.insert(entry.id) }
        entryIDs = ids
        reviewSenseIDs = before.allReviewMaterial || after.allReviewMaterial ? nil :
            Self.reviewIDs(entries: previous.state.entries, ids: ids).union(Self.reviewIDs(entries: state.entries, ids: ids))
        requiresEntryReload = false
    }

    func receipt(from previous: LingroveNotebookSnapshot, to saved: LingroveNotebookSnapshot) -> LingroveNotebookCommittedChange {
        let live = Set(state.entries.map(\.id))
        return .init(base: .init(previous), version: .init(saved),
            updatedEntries: state.entries.filter { entryIDs.contains($0.id) },
            removedEntryIDs: entryIDs.subtracting(live), requiresEntryReload: requiresEntryReload)
    }

    private static func reviewIDs(entries: [VocabularyEntry], ids: Set<UUID>) -> Set<UUID> {
        Set(entries.lazy.filter { ids.contains($0.id) }.flatMap { $0.senses.flatMap { [$0.id] + $0.mergedFrom } })
    }

}
