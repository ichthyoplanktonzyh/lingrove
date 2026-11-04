import Foundation
import LingroveNotebook

extension ReviewNoteStore {
    public func acknowledgedState(workspace: String) throws -> ReviewNoteSyncState? {
        guard let json = try core.scalarOptionalText(sql: "SELECT (SELECT acknowledged_state FROM notebook_note_sync_state WHERE workspace_id=?)",
            values: [.text(workspace)]) else { return nil }
        return try core.decoder.decode(ReviewNoteSyncState.self, from: Data(json.utf8))
    }

    public func hasPendingSync(scope: LingroveNotebookSnapshot) throws -> Bool {
        guard let state = try syncState(scope: scope) else { return false }
        return try core.scalarOptionalText(sql: "SELECT (SELECT acknowledged_digest FROM notebook_note_sync_state WHERE workspace_id=?)",
            values: [.text(scope.workspaceId)]) != state.digest()
    }

    public func acknowledgeState(_ remote: ReviewNoteSyncState, scope: LingroveNotebookSnapshot) throws {
        // If newer local edits survived apply, their digest still differs and remains pending.
        try core.execute(sql: "INSERT INTO notebook_note_sync_state(workspace_id,acknowledged_digest,acknowledged_state) VALUES(?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET acknowledged_digest=excluded.acknowledged_digest,acknowledged_state=excluded.acknowledged_state",
            values: [.text(scope.workspaceId), .text(try remote.digest()), .text(String(decoding: try core.encoder.encode(remote), as: UTF8.self))])
    }

    public func syncState(scope: LingroveNotebookSnapshot) throws -> ReviewNoteSyncState? {
        let storedNotes = try notes(scope: scope)
        let storedTypes = try types(workspace: scope.workspaceId)
        let defaultType = try defaultType(workspace: scope.workspaceId)
        guard !storedNotes.isEmpty || storedTypes != [ReviewNoteDefaults.type] || defaultType.id != ReviewNoteDefaults.type.id else { return nil }
        return .init(types: storedTypes.sorted { $0.id.uuidString < $1.id.uuidString },
            notes: storedNotes.sorted { $0.id.uuidString < $1.id.uuidString },
            memberships: try memberships(workspace: scope.workspaceId), defaultTypeID: defaultType.id, defaultRevision: try defaultRevision(workspace: scope.workspaceId))
    }

    /// Apply a complete server state without overwriting edits made since the request. Equal
    /// revision/different content is a conflict, never a last-writer guess. Types are installed
    /// before notes/membership so rendering cannot observe dangling template references.
    public func applySyncState(_ remote: ReviewNoteSyncState, sent: ReviewNoteSyncState?, scope: LingroveNotebookSnapshot) throws {
        guard remote.types.count <= 256, remote.notes.count <= 100_000,
              Set(remote.types.map(\.id)).count == remote.types.count,
              Set(remote.notes.map(\.id)).count == remote.notes.count,
              Set(remote.memberships.map(\.cardID)).count == remote.memberships.count,
              Set(remote.memberships.map { $0.noteID.uuidString + $0.templateID.uuidString }).count == remote.memberships.count,
              remote.types.contains(where: { $0.id == remote.defaultTypeID }) else { throw LingroveNotebookNetworkError.invalidReply }
        let currentTypes = try types(workspace: scope.workspaceId)
        let currentNotes = try notes(scope: scope)
        for type in remote.types {
            try ReviewTemplateRenderer.validate(type)
            if let local = currentTypes.first(where: { $0.id == type.id }) {
                if local.revision == type.revision && local != type { throw VocabularyError.editConflict }
                if local.revision > type.revision { continue }
                if let original = sent?.types.first(where: { $0.id == local.id }), local != original && local != type {
                    throw VocabularyError.editConflict
                }
            }
            try put(type, workspace: scope.workspaceId)
        }
        for note in remote.notes {
            guard note.revision > 0, let type = remote.types.first(where: { $0.id == note.noteTypeID }),
                  Set(note.customFields.keys).isSubset(of: Set(type.fields.map { $0.id.uuidString.lowercased() })),
                  note.customFields.values.allSatisfy({ $0.utf8.count <= 131_072 }) else { throw LingroveNotebookNetworkError.invalidReply }
            if let local = currentNotes.first(where: { $0.id == note.id }) {
                guard local.noteTypeID == note.noteTypeID, local.entryID == note.entryID, local.senseID == note.senseID else { throw VocabularyError.editConflict }
                if local.revision == note.revision && local != note { throw VocabularyError.editConflict }
                if local.revision > note.revision { continue }
                if let original = sent?.notes.first(where: { $0.id == local.id }), local != original && local != note {
                    throw VocabularyError.editConflict
                }
            }
            try put(note, scope: scope)
        }
        let existing = try memberships(workspace: scope.workspaceId)
        for member in remote.memberships {
            guard let note = remote.notes.first(where: { $0.id == member.noteID }),
                  let type = remote.types.first(where: { $0.id == note.noteTypeID }),
                  type.templates.contains(where: { $0.id == member.templateID }) else { throw LingroveNotebookNetworkError.invalidReply }
            if let prior = existing.first(where: { $0.cardID == member.cardID || ($0.noteID == member.noteID && $0.templateID == member.templateID) }) {
                guard prior == member else { throw VocabularyError.editConflict }
            } else { try attach(member, workspace: scope.workspaceId) }
        }
        let revision = try defaultRevision(workspace: scope.workspaceId)
        let currentDefault = try defaultType(workspace: scope.workspaceId).id
        if remote.defaultRevision == revision && remote.defaultTypeID != currentDefault { throw VocabularyError.editConflict }
        if remote.defaultRevision > revision {
            try setDefault(remote.defaultTypeID, workspace: scope.workspaceId)
            try core.execute(sql: "UPDATE notebook_note_sync_state SET default_revision=? WHERE workspace_id=?",
                values: [.integer(Int64(remote.defaultRevision)), .text(scope.workspaceId)])
        }
    }

    func defaultRevision(workspace: String) throws -> UInt64 {
        UInt64(try core.scalarInt(sql: "SELECT COALESCE((SELECT default_revision FROM notebook_note_sync_state WHERE workspace_id=?),1)",
            values: [.text(workspace)]))
    }
}
