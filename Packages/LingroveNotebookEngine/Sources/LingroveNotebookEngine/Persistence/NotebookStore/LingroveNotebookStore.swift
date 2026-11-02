import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import LingroveNotebookSync
import SQLite3

/// A UI draft names the exact workspace/book and local revision it was read from. This value
/// can cross tasks; the SQLite owner cannot. Local revisions are not cloud entity versions.
public nonisolated struct LingroveNotebookSnapshot: Equatable, Sendable {
    public let workspaceId: String
    public let notebookId: UUID
    public let revision: UInt64
    public let document: VocabularyDocument
    /// Captured in the same transaction as the document, never refreshed when
    /// Save starts: an old draft must not acquire a new account's lifetime.
    public let generation: String

    public init(workspaceId: String, notebookId: UUID, revision: UInt64, document: VocabularyDocument, generation: String) {
        self.workspaceId = workspaceId
        self.notebookId = notebookId
        self.revision = revision
        self.document = document
        self.generation = generation
    }
}

/// Owned once by LocalDatabase, like CardStore. The existing DatabaseCore connection supplies
/// all transactions; this adapter opens no files or second database. Pending rows are a local
/// journal awaiting the notebook server contract, deliberately outside the old sync dispatcher.
public struct LingroveNotebookStore {
    public let core: DatabaseCore

    /// Opening a notebook creates revision zero; only an explicit save/import advances it.
    /// Check every workspace because legacy account replacement can discard inactive shells too.
    public func hasCommittedNotebook() throws -> Bool {
        try self.core.scalarInt(sql: "SELECT EXISTS(SELECT 1 FROM notebook_state WHERE revision>0)", values: []) != 0
    }

    public func load(workspaceId: String, requireActiveWorkspace: Bool = false, binding: LingroveNotebookWindowBinding? = nil) throws -> LingroveNotebookSnapshot {
        try self.core.inTransaction {
            if let binding {
                guard workspaceId == binding.scope.workspaceID.uuidString.lowercased() else { throw LingroveNotebookWindowStoreError.bindingChanged }
                try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            }
            try self.checkActiveWorkspace(workspaceId, required: requireActiveWorkspace)
            try self.ensureNotebook(workspaceId: workspaceId)
            let snapshot = try self.readSnapshot(workspaceId: workspaceId)
            if let binding { try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding) }
            return snapshot
        }
    }

    public func save(
        _ document: VocabularyDocument, basedOn baseline: LingroveNotebookSnapshot,
        restoringBackup: Bool = false, images: [String: Data] = [:], requireActiveWorkspace: Bool = false,
        operationId: String = UUID().uuidString.lowercased()
    ) throws -> LingroveNotebookSnapshot {
        if restoringBackup { try VocabularyDocumentValidation.validate(document) }
        let media = LingroveNotebookMediaStore(core: self.core)
        let staged = try media.stageSuppliedImages(document: document, supplied: images)
        try Task.checkCancellation()
        return try self.core.inTransaction {
            try saveInTransaction(document, basedOn: baseline, restoringBackup: restoringBackup, staged: staged,
                requireActiveWorkspace: requireActiveWorkspace, operationId: operationId)
        }
    }

    /// Account reconciliation borrows its existing writer transaction so the
    /// explicit handoff and ordinary content journal cannot commit separately.
    public func saveInAccountTransaction(_ document: VocabularyDocument, basedOn baseline: LingroveNotebookSnapshot,
                                  staged: Set<VocabularyImageReference>, operationID: String) throws -> LingroveNotebookSnapshot {
        try saveInTransaction(document, basedOn: baseline, restoringBackup: true, staged: staged,
            requireActiveWorkspace: true, operationId: operationID)
    }

    private func saveInTransaction(_ document: VocabularyDocument, basedOn baseline: LingroveNotebookSnapshot,
                                   restoringBackup: Bool, staged: Set<VocabularyImageReference>,
                                   requireActiveWorkspace: Bool, operationId: String) throws -> LingroveNotebookSnapshot {
            let media = LingroveNotebookMediaStore(core: core)
            try self.checkActiveWorkspace(baseline.workspaceId, required: requireActiveWorkspace)
            let current = try self.readSnapshot(workspaceId: baseline.workspaceId)
            guard current.notebookId == baseline.notebookId, current.revision == baseline.revision, current.generation == baseline.generation,
                  current.revision < UInt64(Int64.max) else { throw VocabularyError.editConflict }
            let next = try VocabularyDocumentValidation.prepare(document, previous: current.document, restoringBackup: restoringBackup)
            let publicChange = try VocabularyWirePublicIntent.hasChanges(from: current.document, to: next, notebookID: current.notebookId)
            try media.registerImages(document: next, previous: current.document, staged: staged, workspaceId: current.workspaceId)
            try Task.checkCancellation()
            // A local choice can intentionally differ only in literal Unicode
            // bytes. Persist that value even though Swift String equality folds
            // canonical normalization, just as the remote apply path does.
            let changes = try self.replaceRows(document: next, previous: current.document, workspaceId: current.workspaceId,
                preservingLiteralPayloads: true)
            let revision = current.revision + 1
            let now = nowIsoTimestamp()
            let count = try self.core.execute(sql: """
                UPDATE notebook_state SET revision=?,has_templates=?,updated_at=?
                WHERE workspace_id=? AND notebook_id=? AND revision=?
                """, values: [.integer(Int64(revision)), .integer(next.reviewTemplates == nil ? 0 : 1), .text(now),
                    .text(current.workspaceId), .text(current.notebookId.uuidString), .integer(Int64(current.revision))])
            guard count == 1 else { throw VocabularyError.editConflict }
            try self.recordPending(current: current, revision: revision, changed: changes.changed, removed: changes.removed,
                reviewTemplatesPresent: next.reviewTemplates != nil, publicChange: publicChange, operationId: operationId, now: now)
            let saved = LingroveNotebookSnapshot(workspaceId: current.workspaceId, notebookId: current.notebookId, revision: revision, document: next, generation: current.generation)
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(saved)
            return saved
    }

    public func pendingCount(workspaceId: String) throws -> Int {
        try self.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_pending_transactions WHERE workspace_id=?", values: [.text(workspaceId)])
    }

    /// Shared row writer for local saves and remote apply. The caller already
    /// owns the transaction, validated full candidate and revision fence. Header,
    /// journal and shadow ownership stay with that caller, so downloaded content
    /// cannot accidentally enter the local pending journal as a fresh user edit.
    public func replaceRows(document: VocabularyDocument, previous: VocabularyDocument, workspaceId: String,
                     preservingLiteralPayloads: Bool = false) throws
        -> (changed: [VocabularyPersistenceRow], removed: [VocabularyPersistenceRow]) {
        let before = try VocabularyPersistenceCodec.encode(previous).keyedRows()
        let after = try VocabularyPersistenceCodec.encode(document).keyedRows()
        let changed = try after.values.filter { row in
            guard let old = before[row.key], old == row else { return true }
            // Swift value equality treats NFC/NFD strings as equal. A confirmed
            // remote field clock describes literal bytes, so remote apply also
            // compares sorted-key payload bytes before considering a row clean.
            return preservingLiteralPayloads ? try old.encodedPayload() != row.encodedPayload() : false
        }
        let removed = before.values.filter { after[$0.key] == nil }
        // Deferred NO ACTION relationships let final-valid owners leave and
        // return without cascading into unchanged children. Remove old owners
        // before inserting replacements so unique-key swaps are order independent.
        let retiring = removed + changed.filter { before[$0.key] != nil }
        for entity in VocabularyPersistenceEntity.allCases.reversed() {
            for row in retiring where row.entity == entity {
                try core.execute(sql: "DELETE FROM \(LingroveNotebookSchema.table(entity)) WHERE workspace_id=? AND id=?",
                    values: [.text(workspaceId), .text(row.id)])
            }
        }
        for entity in VocabularyPersistenceEntity.allCases {
            for row in changed where row.entity == entity { try upsert(row, workspaceId: workspaceId) }
        }
        return (changed, removed)
    }

    private func checkActiveWorkspace(_ workspaceId: String, required: Bool) throws {
        if required {
            guard try self.core.scalarOptionalText(sql: "SELECT active_workspace_id FROM app_local_settings WHERE settings_id=1",
                values: []) == workspaceId else { throw VocabularyError.editConflict }
        }
    }

    private func ensureNotebook(workspaceId: String) throws {
        try self.core.execute(sql: """
            INSERT INTO notebook_state(workspace_id,notebook_id,revision,has_templates,updated_at)
            VALUES(?,?,0,0,?) ON CONFLICT(workspace_id) DO NOTHING
            """, values: [.text(workspaceId), .text(UUID().uuidString), .text(nowIsoTimestamp())])
    }

    /// Compound Card/link writers call this only inside the same Core transaction. Unlike load,
    /// it neither opens a nested transaction nor creates a missing notebook implicitly.
    public func readSnapshot(workspaceId: String) throws -> LingroveNotebookSnapshot {
        let headers = try self.core.query(sql: "SELECT notebook_id,revision,has_templates FROM notebook_state WHERE workspace_id=?",
            values: [.text(workspaceId)]) { statement -> (UUID, UInt64, Bool) in
            guard let id = UUID(uuidString: try Self.requiredText(statement, 0)),
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER else { throw VocabularyError.invalidArchive }
            let revision = sqlite3_column_int64(statement, 1), templates = sqlite3_column_int64(statement, 2)
            guard revision >= 0, templates == 0 || templates == 1 else { throw VocabularyError.invalidArchive }
            return (id, UInt64(revision), templates == 1)
        }
        guard let header = headers.first else { throw VocabularyError.editConflict }
        var rows: [VocabularyPersistenceRow] = []
        for entity in VocabularyPersistenceEntity.allCases {
            let columns = ["id", "parent_id", "position", "payload_json"] + entity.indexKeys.map(\.rawValue)
            rows += try self.core.query(sql: "SELECT \(columns.joined(separator: ",")) FROM \(LingroveNotebookSchema.table(entity)) WHERE workspace_id=?",
                values: [.text(workspaceId)]) { statement in
                let position = sqlite3_column_int64(statement, 2)
                guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                      position >= 0, position <= Int64(Int.max) else { throw VocabularyError.invalidArchive }
                let indexes = try Dictionary(uniqueKeysWithValues: entity.indexKeys.enumerated().map {
                    ($0.element, try Self.optionalText(statement, Int32($0.offset + 4)))
                })
                return try .init(entity: entity, id: Self.requiredText(statement, 0),
                    parentID: Self.optionalText(statement, 1), position: Int(position),
                    payload: Data(Self.requiredText(statement, 3).utf8), indexValues: indexes)
            }
        }
        let document = try VocabularyPersistenceCodec.decode(.init(rows: rows, reviewTemplatesPresent: header.2))
        try VocabularyDocumentValidation.validate(document)
        return .init(workspaceId: workspaceId, notebookId: header.0, revision: header.1, document: document,
            generation: try LingroveNotebookLocalScopeStore(core: core).generationInTransaction())
    }

    private func upsert(_ row: VocabularyPersistenceRow, workspaceId: String) throws {
        let columns = ["workspace_id", "id", "parent_id", "position", "payload_json"] + row.entity.indexKeys.map(\.rawValue)
        guard let payload = String(data: try row.encodedPayload(), encoding: .utf8) else { throw VocabularyError.invalidArchive }
        let values: [SQLiteValue] = [.text(workspaceId), .text(row.id), row.parentID.map(SQLiteValue.text) ?? .null,
            .integer(Int64(row.position)), .text(payload)] + row.entity.indexKeys.map { row.indexValue($0).map(SQLiteValue.text) ?? .null }
        let updates = columns.dropFirst(2).map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        try self.core.execute(sql: """
            INSERT INTO \(LingroveNotebookSchema.table(row.entity))(\(columns.joined(separator: ",")))
            VALUES(\(Array(repeating: "?", count: columns.count).joined(separator: ",")))
            ON CONFLICT(workspace_id,id) DO UPDATE SET \(updates)
            """, values: values)
    }

    /// Copy SQLite-owned bytes before the statement is finalized. Unlike a display fallback,
    /// persistence must reject malformed UTF-8 rather than silently replacing source evidence.
    private static func requiredText(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))),
                encoding: .utf8) else { throw VocabularyError.invalidArchive }
        return value
    }

    private static func optionalText(_ statement: OpaquePointer, _ index: Int32) throws -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return try requiredText(statement, index)
    }

    private func recordPending(
        current: LingroveNotebookSnapshot, revision: UInt64, changed: [VocabularyPersistenceRow],
        removed: [VocabularyPersistenceRow], reviewTemplatesPresent: Bool, publicChange: Bool, operationId: String, now: String
    ) throws {
        try self.core.execute(sql: """
            INSERT INTO notebook_pending_transactions(operation_id,workspace_id,notebook_id,base_revision,revision,has_templates,created_at,has_public_change)
            VALUES(?,?,?,?,?,?,?,?)
            """, values: [.text(operationId), .text(current.workspaceId), .text(current.notebookId.uuidString),
                .integer(Int64(current.revision)), .integer(Int64(revision)), .integer(reviewTemplatesPresent ? 1 : 0), .text(now), .integer(publicChange ? 1 : 0)])
        // This journal is local persistence, including optional legacy adapter metadata.
        // Upload projection filters tool-local fields and adds remote versions;
        // this journal remains complete for local recovery and exact retirement.
        let mutations = changed.map { ($0, "upsert") } + removed.map { ($0, "delete") }
        for (position, mutation) in mutations.enumerated() {
            let (row, action) = mutation
            let indexes = Dictionary(uniqueKeysWithValues: row.indexValues.map { ($0.key.rawValue, $0.value) })
            let indexesJSON = try self.core.encodeJsonString(value: indexes)
            let payload = action == "delete" ? nil : String(data: try row.encodedPayload(), encoding: .utf8)
            try self.core.execute(sql: """
                INSERT INTO notebook_pending_rows(operation_id,position,entity,entity_id,action,parent_id,entity_position,payload_json,indexes_json)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, values: [.text(operationId), .integer(Int64(position)), .text(row.entity.rawValue), .text(row.id),
                    .text(action), row.parentID.map(SQLiteValue.text) ?? .null, .integer(Int64(row.position)),
                    payload.map(SQLiteValue.text) ?? .null, .text(indexesJSON)])
        }
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
