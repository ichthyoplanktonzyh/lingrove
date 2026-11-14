import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

extension LingroveNotebookEngine {
    /// One explicit manual batch is one revision, journal and material refresh. Each entry
    /// reuses the current validated state; only touched row groups enter the final difference.
    /// The caller's snapshot is a CAS fence, never the source of validation authority.
    public func saveNotebookEntries(_ entries: [VocabularyEntry], basedOn baseline: LingroveNotebookSnapshot,
                                    images: [String: Data] = [:],
                                    restoringOwnedSemantics original: VocabularySemanticIndex? = nil) throws -> LingroveNotebookSnapshot {
        guard !entries.isEmpty, entries.count <= 100, Set(entries.map(\.id)).count == entries.count,
              original == nil || entries.count == 1 else { throw VocabularyError.invalidContent }
        let media = LingroveNotebookMediaStore(core: core)
        let staged = try images.isEmpty ? [] : media.stageSuppliedImages(document: .init(entries: entries), supplied: images)
        return try core.inTransaction {
            let store = lingroveNotebookStore
            try store.checkActiveWorkspace(baseline.workspaceId, required: true)
            let current = try store.readSnapshot(workspaceId: baseline.workspaceId)
            guard LingroveNotebookVersion(current) == LingroveNotebookVersion(baseline),
                  current.revision < UInt64(Int64.max), let cached = core.notebookSaveCache else {
                throw VocabularyError.editConflict
            }
            var state = cached.state, projection = cached.projection
            var touched = Set<VocabularyPersistenceRow.Key>()
            var ownedSenses = Set<UUID>()
            for entry in entries {
                try Task.checkCancellation()
                if let old = state.entries.first(where: { $0.id == entry.id }) {
                    ownedSenses.formUnion(old.senses.flatMap { [$0.id] + $0.mergedFrom })
                }
                ownedSenses.formUnion(entry.senses.flatMap { [$0.id] + $0.mergedFrom })
                let change = try state.replacing(entry)
                let rows = try projection.applying(change)
                touched.formUnion((rows.changed + rows.removed + rows.repositioned).map(\.key))
                state = change.state; projection = rows.projection
            }
            if let original {
                // Merge undo may restore only patterns/mappings owned by this lexical group.
                // Shared nodes, relations and classifications remain the current values.
                let before = state.document.semantics
                var next = before
                next.patterns.removeAll { ownedSenses.contains($0.senseID) }
                next.mappings.removeAll { ownedSenses.contains($0.senseID) }
                next.patterns += original.patterns.filter { ownedSenses.contains($0.senseID) }
                next.mappings += original.mappings.filter { ownedSenses.contains($0.senseID) }
                let change = try state.changingOrganization(.init(semantics: next, basedOn: before))
                let rows = try projection.applyingOrganization(change)
                touched.formUnion((rows.changed + rows.removed + rows.repositioned).map(\.key))
                state = change.state; projection = rows.projection
            }
            let rows = try projection.difference(from: cached.projection, touching: touched)
            let plan = try LingroveNotebookSavePlan(previous: cached, state: state, rows: rows,
                knownEntryIDs: Set(entries.map(\.id)))
            let isPublic = try plan.hasPublicChanges(previous: cached)
            try media.registerImages(references: state.mediaReferences, existing: cached.state.mediaReferences,
                staged: staged, workspaceId: current.workspaceId)
            try Task.checkCancellation()
            return try store.commit(plan, current: current, publicChange: isPublic,
                operationId: UUID().uuidString.lowercased(), lineage: cached.lineage)
        }
    }
}
