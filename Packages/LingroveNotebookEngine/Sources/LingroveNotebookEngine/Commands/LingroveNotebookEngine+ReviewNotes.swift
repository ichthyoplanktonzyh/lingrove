import Foundation
import LingroveNotebook

/// Note commands compose source fences, type revisions and existing Card writers in one
/// transaction. Neither opening Review nor editing a template starts a round or resets memory.
extension LingroveNotebookEngine {
    public func reviewNoteTypes(scope: LingroveNotebookSnapshot) throws -> [ReviewNoteType] {
        try core.inReadTransaction {
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            return try ReviewNoteStore(core: core).types(workspace: scope.workspaceId)
        }
    }
    public func defaultReviewNoteType(scope: LingroveNotebookSnapshot) throws -> ReviewNoteType {
        try core.inReadTransaction {
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            return try ReviewNoteStore(core: core).defaultType(workspace: scope.workspaceId)
        }
    }
    /// Preparing a Note for an external target does not admit any built-in Card. Only the
    /// explicit enrollment command below creates membership and scheduler records.
    public func prepareReviewNote(selection: VocabularySelection, type: ReviewNoteType,
                                  scope: LingroveNotebookSnapshot) throws -> ReviewNote {
        try core.inTransaction {
            try Task.checkCancellation()
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            let store = ReviewNoteStore(core: core)
            guard try store.types(workspace: scope.workspaceId).contains(type) else { throw VocabularyError.editConflict }
            let note = try previewReviewNoteInTransaction(selection: selection, type: type, scope: scope)
            // Persist the selected definition once: a future bundled default must not silently
            // redefine already-prepared notes before their shared type is explicitly updated.
            try store.put(type, workspace: scope.workspaceId)
            try store.put(note, scope: scope)
            return note
        }
    }

    public func previewReviewNote(selection: VocabularySelection, type: ReviewNoteType,
                                  scope: LingroveNotebookSnapshot) throws -> ReviewNote {
        try core.inReadTransaction { try previewReviewNoteInTransaction(selection: selection, type: type, scope: scope) }
    }

    private func previewReviewNoteInTransaction(selection: VocabularySelection, type: ReviewNoteType,
                                                scope: LingroveNotebookSnapshot) throws -> ReviewNote {
        try requireCurrentScopeInTransaction(scope, requireRevision: true)
        guard let entry = scope.document.collectedEntries.first(where: { $0.id == selection.entryID }),
              let sense = entry.senses.first(where: { $0.id == selection.senseID }) else { throw VocabularyError.editConflict }
        let existing = try ReviewNoteStore(core: core).notes(scope: scope)
        if let note = existing.first(where: { $0.noteTypeID == type.id && ($0.senseID == sense.id || sense.mergedFrom.contains($0.senseID)) }) { return note }
        return ReviewNote(id: LingroveNotebookCardMaterial.stableID("note|" + type.id.uuidString,
            workspace: scope.workspaceId, sense: sense.id), noteTypeID: type.id, entryID: entry.id, senseID: sense.id,
            exampleID: sense.examples.filter { $0.completeness == .sentence }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }.first?.id)
    }

    public func saveReviewNoteType(_ proposed: ReviewNoteType, expected: ReviewNoteType?,
                                  scope: LingroveNotebookSnapshot, makeDefault: Bool = false) throws {
        try core.inTransaction {
            try Task.checkCancellation()
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            let store = ReviewNoteStore(core: core)
            let current = try store.types(workspace: scope.workspaceId).first { $0.id == proposed.id }
            guard current == expected, proposed.revision == (current?.revision ?? 0) + 1 else { throw VocabularyError.editConflict }
            let affected = try store.notes(scope: scope).filter { $0.noteTypeID == proposed.id }
            let noteIDs = Set(affected.map(\.id))
            let usedTemplates = try store.memberships(workspace: scope.workspaceId).filter { noteIDs.contains($0.noteID) }
            guard Set(usedTemplates.map(\.templateID)).isSubset(of: Set(proposed.templates.map(\.id))),
                  affected.allSatisfy({ Set($0.customFields.keys).isSubset(of: Set(proposed.fields.map { $0.id.uuidString.lowercased() })) }) else {
                throw VocabularyError.invalidContent
            }
            try store.put(proposed, workspace: scope.workspaceId)
            if makeDefault { try store.setDefault(proposed.id, workspace: scope.workspaceId) }
            for note in affected where usedTemplates.contains(where: { $0.noteID == note.id }) {
                try store.reconcile(note, type: proposed, scope: scope)
            }
            try store.refreshInTransaction(scope)
        }
    }

    @discardableResult
    public func enrollReviewNotes(selections: [VocabularySelection], type expected: ReviewNoteType,
                                  scope: LingroveNotebookSnapshot) throws -> [ReviewNote] {
        try core.inTransaction {
            try Task.checkCancellation()
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            guard !selections.isEmpty, Set(selections.map(\.senseID)).count == selections.count else { throw VocabularyError.invalidContent }
            let store = ReviewNoteStore(core: core)
            guard try store.types(workspace: scope.workspaceId).contains(expected) else { throw VocabularyError.editConflict }
            try store.put(expected, workspace: scope.workspaceId)
            var result: [ReviewNote] = []
            for selection in selections {
                guard let entry = scope.document.collectedEntries.first(where: { $0.id == selection.entryID }),
                      let sense = entry.senses.first(where: { $0.id == selection.senseID }) else { throw VocabularyError.editConflict }
                let note = try previewReviewNoteInTransaction(selection: selection, type: expected, scope: scope)
                try store.put(note, scope: scope)
                try store.reconcile(note, type: expected, scope: scope)
                guard try store.memberships(workspace: scope.workspaceId).contains(where: { $0.noteID == note.id }) else { throw VocabularyError.invalidContent }
                let source = LingroveNotebookCardSource(workspaceId: scope.workspaceId, notebookId: scope.notebookId,
                    entryId: entry.id, senseId: sense.id, exampleId: note.exampleID)
                for enrollment in try lingroveNotebookReviewStore.matching(source: source, snapshot: scope) {
                    _ = try lingroveNotebookReviewStore.update(enrollment, status: .active)
                }
                result.append(note)
            }
            try store.refreshInTransaction(scope)
            return result
        }
    }

    public func saveReviewNote(_ proposed: ReviewNote, expected: ReviewNote, scope: LingroveNotebookSnapshot) throws {
        try core.inTransaction {
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            let store = ReviewNoteStore(core: core)
            guard proposed.id == expected.id, proposed.noteTypeID == expected.noteTypeID,
                  proposed.senseID == expected.senseID, proposed.entryID == expected.entryID,
                  proposed.revision == expected.revision + 1, try store.notes(scope: scope).contains(expected),
                  let type = try store.types(workspace: scope.workspaceId).first(where: { $0.id == proposed.noteTypeID }),
                  Set(proposed.customFields.keys).isSubset(of: Set(type.fields.map { $0.id.uuidString.lowercased() })),
                  proposed.customFields.values.allSatisfy({ $0.utf8.count <= 131_072 }) else { throw VocabularyError.editConflict }
            try store.put(proposed, scope: scope)
            if try store.memberships(workspace: scope.workspaceId).contains(where: { $0.noteID == proposed.id }) {
                try store.reconcile(proposed, type: type, scope: scope)
            }
            try store.refreshInTransaction(scope)
        }
    }

}
