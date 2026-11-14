import Foundation
import LingroveNotebook

/// Shares the notebook connection and transaction with Cards and enrollments. Definitions and
/// notes are stored once; membership refers to them by stable ID, never by copied HTML or order.
public struct ReviewNoteStore {
    public let core: DatabaseCore
    public init(core: DatabaseCore) { self.core = core }
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_note_sync_state(
          workspace_id TEXT PRIMARY KEY REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
          acknowledged_digest TEXT NOT NULL, acknowledged_state TEXT, default_revision INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS notebook_note_types(
          workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
          type_id TEXT NOT NULL, payload_json TEXT NOT NULL, is_default INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(workspace_id,type_id));
        CREATE UNIQUE INDEX IF NOT EXISTS notebook_default_note_type ON notebook_note_types(workspace_id) WHERE is_default=1;
        CREATE TABLE IF NOT EXISTS notebook_notes(
          workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
          note_id TEXT NOT NULL, notebook_id TEXT NOT NULL, payload_json TEXT NOT NULL,
          PRIMARY KEY(workspace_id,note_id));
        CREATE INDEX IF NOT EXISTS notebook_notes_by_source
          ON notebook_notes(workspace_id,notebook_id,json_extract(payload_json,'$.senseID'));
        CREATE INDEX IF NOT EXISTS notebook_notes_by_type
          ON notebook_notes(workspace_id,notebook_id,json_extract(payload_json,'$.noteTypeID'));
        CREATE TABLE IF NOT EXISTS notebook_note_cards(
          workspace_id TEXT NOT NULL, note_id TEXT NOT NULL, template_id TEXT NOT NULL, card_id TEXT NOT NULL,
          PRIMARY KEY(workspace_id,note_id,template_id), UNIQUE(workspace_id,card_id),
          FOREIGN KEY(workspace_id,note_id) REFERENCES notebook_notes(workspace_id,note_id) ON DELETE CASCADE);
        """
    public static let resetSQL = """
        DROP TABLE IF EXISTS notebook_note_sync_state;
        DROP TABLE IF EXISTS notebook_note_cards;
        DROP TABLE IF EXISTS notebook_notes;
        DROP TABLE IF EXISTS notebook_note_types;
        """

    public func types(workspace: String) throws -> [ReviewNoteType] {
        let stored: [ReviewNoteType] = try values(table: "notebook_note_types", workspace: workspace)
        for type in stored { try ReviewTemplateRenderer.validate(type) }
        return stored.contains(where: { $0.id == ReviewNoteDefaults.type.id }) ? stored : [ReviewNoteDefaults.type] + stored
    }

    /// Source edits borrow definitions only for selected Notes. Other definition payloads
    /// cannot make a one-entry refresh scale with the number of unrelated custom types.
    func types(workspace: String, ids: Set<UUID>) throws -> [ReviewNoteType] {
        guard !ids.isEmpty else { return [] }
        let encoded = try json(ids.map(\.uuidString))
        var stored: [ReviewNoteType] = try core.query(sql: """
            SELECT payload_json FROM notebook_note_types WHERE workspace_id=?
              AND type_id IN (SELECT value FROM json_each(?))
            """, values: [.text(workspace), .text(encoded)]) {
            try core.decoder.decode(ReviewNoteType.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8))
        }
        if ids.contains(ReviewNoteDefaults.type.id), !stored.contains(where: { $0.id == ReviewNoteDefaults.type.id }) {
            stored.append(ReviewNoteDefaults.type)
        }
        for type in stored { try ReviewTemplateRenderer.validate(type) }
        return stored
    }
    public func defaultType(workspace: String) throws -> ReviewNoteType {
        let values: [ReviewNoteType] = try core.query(sql: "SELECT payload_json FROM notebook_note_types WHERE workspace_id=? AND is_default=1",
            values: [.text(workspace)]) { try core.decoder.decode(ReviewNoteType.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8)) }
        return try values.first ?? type(id: ReviewNoteDefaults.type.id, workspace: workspace) ?? ReviewNoteDefaults.type
    }
    public func notes(scope: LingroveNotebookSnapshot) throws -> [ReviewNote] {
        try notes(version: .init(scope))
    }

    func notes(version: LingroveNotebookVersion) throws -> [ReviewNote] {
        try core.query(sql: "SELECT payload_json FROM notebook_notes WHERE workspace_id=? AND notebook_id=? ORDER BY note_id",
            values: [.text(version.workspaceId), .text(version.notebookId.uuidString)]) {
            try core.decoder.decode(ReviewNote.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8))
        }
    }

    /// Historical and handed-off notes can have IDs other than the local generated ID.
    /// Find them by saved source and preserve the same note order as the full collection.
    func notes(version: LingroveNotebookVersion, senseIDs: Set<UUID>) throws -> [ReviewNote] {
        guard !senseIDs.isEmpty else { return [] }
        let ids = try core.encoder.encode(senseIDs.map(\.uuidString))
        let selected = try core.query(sql: """
            SELECT payload_json FROM notebook_notes WHERE workspace_id=? AND notebook_id=?
            AND json_extract(payload_json,'$.senseID') IN (SELECT value FROM json_each(?))
            """, values: [.text(version.workspaceId), .text(version.notebookId.uuidString), .text(String(decoding: ids, as: UTF8.self))]) {
            try core.decoder.decode(ReviewNote.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8))
        }
        // SQL ordering can prefer the workspace-wide primary key over the selective source
        // index. Keep the established deterministic return order on this small result only.
        return selected.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    /// Writers admit one Note by its primary key, or one type's dependents through an index.
    /// The notebook restriction remains part of ownership even when a Note ID is known.
    func note(id: UUID, version: LingroveNotebookVersion) throws -> ReviewNote? {
        try core.query(sql: "SELECT payload_json FROM notebook_notes WHERE workspace_id=? AND note_id=? AND notebook_id=?",
            values: [.text(version.workspaceId), .text(id.uuidString), .text(version.notebookId.uuidString)]) {
            try core.decoder.decode(ReviewNote.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8))
        }.first
    }

    func notes(version: LingroveNotebookVersion, typeID: UUID) throws -> [ReviewNote] {
        let selected = try core.query(sql: """
            SELECT payload_json FROM notebook_notes WHERE workspace_id=? AND notebook_id=?
              AND json_extract(payload_json,'$.noteTypeID')=?
            """, values: [.text(version.workspaceId), .text(version.notebookId.uuidString), .text(typeID.uuidString)]) {
            try core.decoder.decode(ReviewNote.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8))
        }
        return selected.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func type(id: UUID, workspace: String) throws -> ReviewNoteType? {
        try types(workspace: workspace, ids: [id]).first
    }

    public func memberships(workspace: String) throws -> [Membership] {
        try memberships(workspace: workspace, noteID: nil)
    }

    func memberships(workspace: String, noteID: UUID?) throws -> [Membership] {
        let restriction = noteID == nil ? "" : " AND note_id=?"
        var values: [SQLiteValue] = [.text(workspace)]
        if let noteID { values.append(.text(noteID.uuidString)) }
        return try core.query(sql: """
            SELECT note_id,template_id,card_id FROM notebook_note_cards
            WHERE workspace_id=?\(restriction) ORDER BY card_id
            """, values: values) {
            guard let note = UUID(uuidString: DatabaseCore.columnText(statement: $0, index: 0)),
                  let template = UUID(uuidString: DatabaseCore.columnText(statement: $0, index: 1)) else { throw VocabularyError.invalidArchive }
            return .init(noteID: note, templateID: template, cardID: DatabaseCore.columnText(statement: $0, index: 2))
        }
    }

    /// Narrow corpus writes select Notes by source first, then borrow only their membership
    /// rows. JSON array binding keeps large batches under SQLite's parameter limit.
    func memberships(workspace: String, noteIDs: Set<UUID>) throws -> [Membership] {
        guard !noteIDs.isEmpty else { return [] }
        let ids = String(decoding: try core.encoder.encode(noteIDs.map(\.uuidString).sorted()), as: UTF8.self)
        let selected: [Membership] = try core.query(sql: """
            SELECT note_id,template_id,card_id FROM notebook_note_cards
            WHERE workspace_id=? AND note_id IN (SELECT value FROM json_each(?))
            """, values: [.text(workspace), .text(ids)]) { row in
            guard let note = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                  let template = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)) else {
                throw VocabularyError.invalidArchive
            }
            return .init(noteID: note, templateID: template, cardID: DatabaseCore.columnText(statement: row, index: 2))
        }
        // Match the full interface's card order after the note-owner index constrains rows.
        return selected.sorted { $0.cardID < $1.cardID }
    }

    func ownedCardIDs(workspace: String, cardIDs: Set<String>) throws -> Set<String> {
        guard !cardIDs.isEmpty else { return [] }
        let ids = String(decoding: try core.encoder.encode(cardIDs.sorted()), as: UTF8.self)
        return Set(try core.query(sql: """
            SELECT card_id FROM notebook_note_cards
            WHERE workspace_id=? AND card_id IN (SELECT value FROM json_each(?))
            """, values: [.text(workspace), .text(ids)]) { DatabaseCore.columnText(statement: $0, index: 0) })
    }
    public struct Membership: Codable, Hashable, Sendable {
        public let noteID: UUID
        public let templateID: UUID
        public let cardID: String
        public init(noteID: UUID, templateID: UUID, cardID: String) { self.noteID = noteID; self.templateID = templateID; self.cardID = cardID }
    }
    public func put(_ type: ReviewNoteType, workspace: String) throws {
        try ReviewTemplateRenderer.validate(type)
        try core.execute(sql: "INSERT INTO notebook_note_types(workspace_id,type_id,payload_json) VALUES(?,?,?) ON CONFLICT(workspace_id,type_id) DO UPDATE SET payload_json=excluded.payload_json",
            values: [.text(workspace), .text(type.id.uuidString), .text(try json(type))])
    }
    public func setDefault(_ id: UUID, workspace: String) throws {
        guard try type(id: id, workspace: workspace) != nil else { throw VocabularyError.invalidContent }
        if id == ReviewNoteDefaults.type.id, try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_note_types WHERE workspace_id=? AND type_id=?", values: [.text(workspace), .text(id.uuidString)]) == 0 {
            try put(ReviewNoteDefaults.type, workspace: workspace)
        }
        if try defaultType(workspace: workspace).id != id {
            try core.execute(sql: "INSERT INTO notebook_note_sync_state(workspace_id,acknowledged_digest,default_revision) VALUES(?,'',2) ON CONFLICT(workspace_id) DO UPDATE SET default_revision=default_revision+1",
                values: [.text(workspace)])
        }
        try core.execute(sql: "UPDATE notebook_note_types SET is_default=(type_id=?) WHERE workspace_id=?", values: [.text(id.uuidString), .text(workspace)])
    }
    public func put(_ note: ReviewNote, scope: LingroveNotebookSnapshot) throws {
        try put(note, version: .init(scope))
    }
    func put(_ note: ReviewNote, version: LingroveNotebookVersion) throws {
        try core.execute(sql: "INSERT INTO notebook_notes(workspace_id,note_id,notebook_id,payload_json) VALUES(?,?,?,?) ON CONFLICT(workspace_id,note_id) DO UPDATE SET payload_json=excluded.payload_json",
            values: [.text(version.workspaceId), .text(note.id.uuidString), .text(version.notebookId.uuidString), .text(try json(note))])
    }
    public func attach(_ member: Membership, workspace: String) throws {
        try core.execute(sql: "INSERT INTO notebook_note_cards(workspace_id,note_id,template_id,card_id) VALUES(?,?,?,?)",
            values: [.text(workspace), .text(member.noteID.uuidString), .text(member.templateID.uuidString), .text(member.cardID)])
    }
    private func values<T: Decodable>(table: String, workspace: String) throws -> [T] {
        try core.query(sql: "SELECT payload_json FROM \(table) WHERE workspace_id=? ORDER BY type_id", values: [.text(workspace)]) {
            try core.decoder.decode(T.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8))
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try core.encoder.encode(value), as: UTF8.self) }
}
