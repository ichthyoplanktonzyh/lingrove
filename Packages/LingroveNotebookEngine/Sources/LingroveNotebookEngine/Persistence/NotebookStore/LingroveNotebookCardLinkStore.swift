import Foundation
import LingroveNotebook
import SQLite3

/// LocalDatabase owns this adapter on its existing Core. Compound writers own the transaction;
/// this store never opens another connection or nests a transaction. It persists provenance and
/// the notebook-only journal, while the original CardStore remains the sole Card/FSRS owner.
public struct LingroveNotebookCardLinkStore {
    public let core: DatabaseCore

    private static let columns = "workspace_id,link_id,notebook_id,entry_id,sense_id,example_id,card_id,generated_content_json,source_revision,creation_fingerprint,revision,created_at,updated_at,deleted_at,allows_unavailable_material"

    public func load(workspaceId: String, cardId: String? = nil, includingDeleted: Bool = false) throws -> [LingroveNotebookCardLink] {
        let cardClause = cardId == nil ? "" : " AND card_id=?"
        let liveClause = includingDeleted ? "" : " AND deleted_at IS NULL"
        return try self.core.query(sql: """
            SELECT \(Self.columns) FROM notebook_card_links WHERE workspace_id=?\(cardClause)\(liveClause)
            ORDER BY created_at,link_id
            """, values: [.text(workspaceId)] + (cardId.map { [.text($0)] } ?? []), map: self.decode)
    }

    public func find(workspaceId: String, id: UUID) throws -> LingroveNotebookCardLink? {
        try self.core.query(sql: "SELECT \(Self.columns) FROM notebook_card_links WHERE workspace_id=? AND link_id=?",
            values: [.text(workspaceId), .text(id.uuidString)], map: self.decode).first
    }

    public func validate(_ draft: LingroveNotebookCardDraft) throws -> LingroveNotebookSnapshot {
        try self.requireActiveScope(draft.source)
        let snapshot = try LingroveNotebookStore(core: self.core).readSnapshot(workspaceId: draft.source.workspaceId)
        try self.validate(draft, against: snapshot)
        return snapshot
    }

    /// A compound batch reads its saved document once inside the writer transaction. This
    /// deterministic check reuses that exact baseline, avoiding a full book decode per sense.
    public func validate(_ draft: LingroveNotebookCardDraft, against snapshot: LingroveNotebookSnapshot) throws {
        guard snapshot.workspaceId == draft.source.workspaceId, snapshot.notebookId == draft.source.notebookId,
              snapshot.revision == draft.sourceRevision,
              let current = LingroveNotebookCardMaterial.resolve(source: draft.source, snapshot: snapshot),
              current.selection == VocabularySelection(entryID: draft.source.entryId, senseID: draft.source.senseId),
              current.content == draft.generatedContent else { throw VocabularyError.editConflict }
    }

    public func requireActiveScope(_ source: LingroveNotebookCardSource) throws {
        try self.requireActiveScope(workspaceId: source.workspaceId, notebookId: source.notebookId)
    }

    public func requireActiveScope(workspaceId: String, notebookId: UUID) throws {
        guard try self.core.scalarOptionalText(sql: "SELECT active_workspace_id FROM app_local_settings WHERE settings_id=1",
            values: []) == workspaceId,
              try self.core.scalarOptionalText(sql: "SELECT notebook_id FROM notebook_state WHERE workspace_id=?",
                values: [.text(workspaceId)]) == notebookId.uuidString else { throw VocabularyError.editConflict }
    }

    public func insert(
        draft: LingroveNotebookCardDraft, cardId: String, generatedContent: CardEditorInput?, fingerprint: String,
        cardOperationId: String?, now: String
    ) throws -> LingroveNotebookCardLink {
        let link = LingroveNotebookCardLink(id: draft.id, source: draft.source, cardId: cardId,
            generatedContent: generatedContent, sourceRevision: draft.sourceRevision, creationFingerprint: fingerprint,
            revision: 1, createdAt: now, updatedAt: now, deletedAt: nil)
        try self.core.execute(sql: """
            INSERT INTO notebook_card_links(\(Self.columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, values: try self.values(link))
        try self.record(link: link, baseRevision: 0, cardOperationId: cardOperationId)
        return link
    }

    public func update(
        _ expected: LingroveNotebookCardLink, generatedContent: CardEditorInput?, sourceRevision: UInt64,
        cardId: String? = nil, source: LingroveNotebookCardSource? = nil, allowingUnavailableMaterial: Bool? = nil, deleting: Bool = false, cardOperationId: String? = nil
    ) throws -> LingroveNotebookCardLink {
        guard expected.deletedAt == nil, expected.revision < UInt64(Int64.max),
              sourceRevision <= UInt64(Int64.max) else { throw VocabularyError.editConflict }
        let now = max(nowIsoTimestamp(), formatIsoTimestamp(date: (parseIsoTimestamp(value: expected.updatedAt) ?? .distantPast).addingTimeInterval(0.001)))
        let next = LingroveNotebookCardLink(id: expected.id, source: source ?? expected.source, cardId: cardId ?? expected.cardId,
            generatedContent: generatedContent, sourceRevision: sourceRevision, creationFingerprint: expected.creationFingerprint,
            revision: expected.revision + 1, createdAt: expected.createdAt, updatedAt: now, deletedAt: deleting ? now : nil, allowsUnavailableMaterial: allowingUnavailableMaterial ?? expected.allowsUnavailableMaterial)
        let contentJSON = try generatedContent.map { try self.core.encodeJsonString(value: $0) }
        let count = try self.core.execute(sql: """
            UPDATE notebook_card_links SET example_id=?,card_id=?,generated_content_json=?,source_revision=?,revision=?,updated_at=?,deleted_at=?,allows_unavailable_material=?
            WHERE workspace_id=? AND link_id=? AND revision=? AND deleted_at IS NULL
            """, values: [next.source.exampleId.map { .text($0.uuidString) } ?? .null, .text(next.cardId), contentJSON.map(SQLiteValue.text) ?? .null,
                .integer(Int64(sourceRevision)), .integer(Int64(next.revision)), .text(now), next.deletedAt.map(SQLiteValue.text) ?? .null, .integer(next.allowsUnavailableMaterial ? 1 : 0),
                .text(expected.source.workspaceId), .text(expected.id.uuidString), .integer(Int64(expected.revision))])
        guard count == 1 else { throw VocabularyError.editConflict }
        try self.record(link: next, baseRevision: expected.revision, cardOperationId: cardOperationId)
        return next
    }

    public func isHeld(workspaceId: String, cardId: String) throws -> Bool {
        try self.core.scalarInt(sql: "SELECT EXISTS(SELECT 1 FROM notebook_card_sync_holds WHERE workspace_id=? AND card_id=?)",
            values: [.text(workspaceId), .text(cardId)]) != 0
    }

    public func heldCardIds(workspaceId: String) throws -> Set<String> {
        Set(try self.core.query(sql: "SELECT card_id FROM notebook_card_sync_holds WHERE workspace_id=?",
            values: [.text(workspaceId)]) { DatabaseCore.columnText(statement: $0, index: 0) })
    }

    /// The initial native create wrote its ordinary outbox row earlier in this same transaction.
    /// Move it before commit, then route every later edit/review to the separate held journal.
    /// Old push/ack/cleanup can never observe or erase a partially published notebook exercise.
    public func holdCreatedCard(_ card: Card, source: LingroveNotebookCardSource, now: String) throws {
        try self.core.execute(sql: """
            INSERT INTO notebook_card_sync_holds(workspace_id,card_id,notebook_id,creation_operation_id,created_at)
            VALUES(?,?,?,?,?)
            """, values: [.text(card.workspaceId), .text(card.cardId), .text(source.notebookId.uuidString),
                .text(card.lastOperationId), .text(now)])
        let columns = LingroveNotebookCardLinkSchema.operationColumns
        try self.core.execute(sql: """
            INSERT INTO notebook_held_card_operations(\(columns),subject_card_id)
            SELECT \(columns),? FROM outbox WHERE workspace_id=? AND entity_type='card' AND entity_id=?
            """, values: [.text(card.cardId), .text(card.workspaceId), .text(card.cardId)])
        try self.core.execute(sql: "DELETE FROM outbox WHERE workspace_id=? AND entity_type='card' AND entity_id=?",
            values: [.text(card.workspaceId), .text(card.cardId)])
    }

    /// Public-ID conflict repair already owns a Core transaction. Historical pending link rows
    /// remain a local journal; the future wire projection must coalesce to this current target.
    public func rewriteCardId(workspaceId: String, from oldId: String, to newId: String) throws {
        for link in try self.load(workspaceId: workspaceId, cardId: oldId, includingDeleted: true) {
            let now = nowIsoTimestamp()
            guard link.revision < UInt64(Int64.max) else { throw VocabularyError.editConflict }
            let next = LingroveNotebookCardLink(id: link.id, source: link.source, cardId: newId,
                generatedContent: link.generatedContent, sourceRevision: link.sourceRevision,
                creationFingerprint: link.creationFingerprint, revision: link.revision + 1,
                createdAt: link.createdAt, updatedAt: now, deletedAt: link.deletedAt, allowsUnavailableMaterial: link.allowsUnavailableMaterial)
            try self.core.execute(sql: "UPDATE notebook_card_links SET card_id=?,revision=?,updated_at=? WHERE workspace_id=? AND link_id=?",
                values: [.text(newId), .integer(Int64(next.revision)), .text(now), .text(workspaceId), .text(link.id.uuidString)])
            try self.record(link: next, baseRevision: link.revision, cardOperationId: nil)
        }
        try LingroveNotebookReviewStore(core: self.core).rewriteCardId(workspaceId: workspaceId, from: oldId, to: newId)
    }

    public func record(link: LingroveNotebookCardLink, baseRevision: UInt64, cardOperationId: String?) throws {
        try self.core.execute(sql: """
            INSERT INTO notebook_card_link_operations(operation_id,workspace_id,link_id,base_revision,revision,card_operation_id,payload_json,created_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, values: [.text(UUID().uuidString.lowercased()), .text(link.source.workspaceId), .text(link.id.uuidString),
                .integer(Int64(baseRevision)), .integer(Int64(link.revision)), cardOperationId.map(SQLiteValue.text) ?? .null,
                .text(try self.core.encodeJsonString(value: link)), .text(link.updatedAt)])
    }

    private func values(_ link: LingroveNotebookCardLink) throws -> [SQLiteValue] {
        let content = try link.generatedContent.map { try self.core.encodeJsonString(value: $0) }
        return [.text(link.source.workspaceId), .text(link.id.uuidString), .text(link.source.notebookId.uuidString),
            .text(link.source.entryId.uuidString), .text(link.source.senseId.uuidString), link.source.exampleId.map { .text($0.uuidString) } ?? .null,
            .text(link.cardId), content.map(SQLiteValue.text) ?? .null, .integer(Int64(link.sourceRevision)),
            .text(link.creationFingerprint), .integer(Int64(link.revision)), .text(link.createdAt), .text(link.updatedAt),
            link.deletedAt.map(SQLiteValue.text) ?? .null, .integer(link.allowsUnavailableMaterial ? 1 : 0)]
    }

    private func decode(_ statement: OpaquePointer) throws -> LingroveNotebookCardLink {
        func uuid(_ index: Int32) throws -> UUID {
            guard let value = UUID(uuidString: DatabaseCore.columnText(statement: statement, index: index)) else {
                throw VocabularyError.invalidArchive
            }
            return value
        }
        let example = try DatabaseCore.columnOptionalText(statement: statement, index: 5).map { value -> UUID in
            guard let id = UUID(uuidString: value) else { throw VocabularyError.invalidArchive }; return id
        }
        let content = try DatabaseCore.columnOptionalText(statement: statement, index: 7).map {
            try self.core.decoder.decode(CardEditorInput.self, from: Data($0.utf8))
        }
        let sourceRevision = DatabaseCore.columnInt64(statement: statement, index: 8)
        let revision = DatabaseCore.columnInt64(statement: statement, index: 10)
        guard sqlite3_column_type(statement, 8) == SQLITE_INTEGER, sqlite3_column_type(statement, 10) == SQLITE_INTEGER,
              sourceRevision >= 0, revision > 0 else { throw VocabularyError.invalidArchive }
        return .init(id: try uuid(1), source: .init(workspaceId: DatabaseCore.columnText(statement: statement, index: 0),
            notebookId: try uuid(2), entryId: try uuid(3), senseId: try uuid(4), exampleId: example),
            cardId: DatabaseCore.columnText(statement: statement, index: 6), generatedContent: content,
            sourceRevision: UInt64(sourceRevision), creationFingerprint: DatabaseCore.columnText(statement: statement, index: 9),
            revision: UInt64(revision), createdAt: DatabaseCore.columnText(statement: statement, index: 11),
            updatedAt: DatabaseCore.columnText(statement: statement, index: 12), deletedAt: DatabaseCore.columnOptionalText(statement: statement, index: 13), allowsUnavailableMaterial: DatabaseCore.columnInt64(statement: statement, index: 14) != 0)
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
