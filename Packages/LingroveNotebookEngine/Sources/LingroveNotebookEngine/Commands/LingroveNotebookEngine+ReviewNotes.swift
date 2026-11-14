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
            guard try store.type(id: type.id, workspace: scope.workspaceId) == type else { throw VocabularyError.editConflict }
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
        let (entry, sense) = try ReviewNoteStore(core: core).source(for: selection, workspace: scope.workspaceId)
        return try reviewNote(entry: entry, sense: sense, type: type, version: .init(scope))
    }

    private func reviewNote(entry: VocabularyEntry, sense: VocabularySense, type: ReviewNoteType,
                            version: LingroveNotebookVersion) throws -> ReviewNote {
        let existing = try ReviewNoteStore(core: core).notes(version: version, senseIDs: Set([sense.id] + sense.mergedFrom))
        if let note = existing.first(where: { $0.noteTypeID == type.id }) { return note }
        return ReviewNote(id: LingroveNotebookCardMaterial.stableID("note|" + type.id.uuidString,
            workspace: version.workspaceId, sense: sense.id), noteTypeID: type.id, entryID: entry.id, senseID: sense.id,
            exampleID: sense.examples.lazy.filter { $0.completeness == .sentence }.min {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }?.id)
    }

    public func saveReviewNoteType(_ proposed: ReviewNoteType, expected: ReviewNoteType?,
                                  scope: LingroveNotebookSnapshot, makeDefault: Bool = false) throws {
        _ = try saveReviewNoteTypeWithReceipt(proposed, expected: expected, scope: scope, makeDefault: makeDefault)
    }

    public func saveReviewNoteTypeWithReceipt(_ proposed: ReviewNoteType, expected: ReviewNoteType?,
                                              scope: LingroveNotebookSnapshot, makeDefault: Bool = false) throws -> NotebookReviewEdit {
        try core.inTransaction {
            try Task.checkCancellation()
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            let store = ReviewNoteStore(core: core)
            let version = LingroveNotebookVersion(scope)
            let baseReview = try core.notebookChangeStamp().review
            let current = try store.type(id: proposed.id, workspace: scope.workspaceId)
            guard current == expected, proposed.revision == (current?.revision ?? 0) + 1 else { throw VocabularyError.editConflict }
            // CSS and the type's display name do not change generated plain faces or template
            // admission. The type revision still fences stale questions and syncs the new style.
            if let current, current.fields == proposed.fields, current.templates == proposed.templates {
                try store.put(proposed, workspace: scope.workspaceId)
                if makeDefault { try store.setDefault(proposed.id, workspace: scope.workspaceId) }
                return try reviewEdit(scope: scope, base: baseReview, style: proposed)
            }
            let fieldIDs = Set(proposed.fields.map { $0.id.uuidString.lowercased() })
            let affected = try store.notes(version: version, typeID: proposed.id)
            let noteIDs = Set(affected.map(\.id))
            let usedTemplates = try store.memberships(workspace: scope.workspaceId, noteIDs: noteIDs)
            guard Set(usedTemplates.map(\.templateID)).isSubset(of: Set(proposed.templates.map(\.id))),
                  affected.allSatisfy({ Set($0.customFields.keys).isSubset(of: fieldIDs) }) else {
                throw VocabularyError.invalidContent
            }
            try store.put(proposed, workspace: scope.workspaceId)
            if makeDefault { try store.setDefault(proposed.id, workspace: scope.workspaceId) }
            try store.refreshNotes(affected, definitions: [proposed], members: usedTemplates, version: version) {
                try store.source(for: $0, workspace: scope.workspaceId)
            }
            return try reviewEdit(scope: scope, base: baseReview)
        }
    }

    @discardableResult
    public func enrollReviewNotes(selections: [VocabularySelection], type expected: ReviewNoteType,
                                  scope: LingroveNotebookSnapshot) throws -> [ReviewNote] {
        try enrollReviewNotes(selections: selections, type: expected, version: .init(scope))
    }

    /// The corpus button uses the current default inside the same transaction as admission.
    /// Loading a queue first would duplicate work and pin a template that may no longer be current.
    @discardableResult
    public func enrollReviewNotes(selections: [VocabularySelection], version: LingroveNotebookVersion) throws -> [ReviewNote] {
        try enrollReviewNotes(selections: selections, type: nil, version: version)
    }

    private func enrollReviewNotes(selections: [VocabularySelection], type expected: ReviewNoteType?,
                                   version: LingroveNotebookVersion) throws -> [ReviewNote] {
        try core.inTransaction {
            try Task.checkCancellation()
            guard try currentNotebookVersionInTransaction() == version else { throw VocabularyError.editConflict }
            guard !selections.isEmpty, Set(selections.map(\.senseID)).count == selections.count else { throw VocabularyError.invalidContent }
            let store = ReviewNoteStore(core: core)
            let type: ReviewNoteType
            if let expected {
                guard try store.type(id: expected.id, workspace: version.workspaceId) == expected else { throw VocabularyError.editConflict }
                type = expected
            } else {
                type = try store.defaultType(workspace: version.workspaceId)
            }
            try store.put(type, workspace: version.workspaceId)
            var result: [ReviewNote] = []
            for selection in selections {
                try Task.checkCancellation()
                let (entry, sense) = try store.source(for: selection, workspace: version.workspaceId)
                let note = try reviewNote(entry: entry, sense: sense, type: type, version: version)
                try store.put(note, version: version)
                let members = try store.reconcile(note, type: type, version: version, entry: entry, sense: sense)
                guard !members.isEmpty else { throw VocabularyError.invalidContent }
                let aliases = Set([sense.id] + sense.mergedFrom)
                for enrollment in try lingroveNotebookReviewStore.load(workspaceId: version.workspaceId,
                    notebookId: version.notebookId, senseIDs: aliases) {
                    _ = try lingroveNotebookReviewStore.update(enrollment, status: .active)
                }
                for member in members {
                    let model = NotebookReviewNoteCard(note: note, noteType: type, templateID: member.templateID)
                    try store.refreshCard(member.cardID, model: model, version: version, source: (entry, sense))
                }
                result.append(note)
            }
            try Task.checkCancellation()
            return result
        }
    }

    public func saveReviewNote(_ proposed: ReviewNote, expected: ReviewNote, scope: LingroveNotebookSnapshot) throws {
        _ = try saveReviewNoteWithReceipt(proposed, expected: expected, scope: scope)
    }

    public func saveReviewNoteWithReceipt(_ proposed: ReviewNote, expected: ReviewNote, scope: LingroveNotebookSnapshot) throws -> NotebookReviewEdit {
        try core.inTransaction {
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            try Task.checkCancellation()
            let store = ReviewNoteStore(core: core)
            let version = LingroveNotebookVersion(scope)
            let baseReview = try core.notebookChangeStamp().review
            guard proposed.id == expected.id, proposed.noteTypeID == expected.noteTypeID,
                  proposed.senseID == expected.senseID, proposed.entryID == expected.entryID,
                  proposed.revision == expected.revision + 1, try store.note(id: expected.id, version: version) == expected,
                  let type = try store.type(id: proposed.noteTypeID, workspace: scope.workspaceId),
                  Set(proposed.customFields.keys).isSubset(of: Set(type.fields.map { $0.id.uuidString.lowercased() })),
                  proposed.customFields.values.allSatisfy({ $0.utf8.count <= 131_072 }) else { throw VocabularyError.editConflict }
            try store.put(proposed, scope: scope)
            let members = try store.memberships(workspace: scope.workspaceId, noteID: proposed.id)
            try store.refreshNotes([proposed], definitions: [type], members: members, version: version) {
                try store.source(for: $0, workspace: scope.workspaceId)
            }
            let source = try store.source(for: proposed, workspace: scope.workspaceId)
            let ids = Set([proposed.senseID] + (source.map { [$0.1.id] + $0.1.mergedFrom } ?? []))
            return try reviewEdit(scope: scope, base: baseReview, senseIDs: ids)
        }
    }

}
