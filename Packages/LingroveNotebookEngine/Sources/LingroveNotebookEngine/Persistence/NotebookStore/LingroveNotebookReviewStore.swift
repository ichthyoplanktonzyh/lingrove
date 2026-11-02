import Foundation
import LingroveNotebook
import SQLite3

/// LocalDatabase owns this value adapter on its existing Core. The facade owns transactions;
/// this store only persists participation, exercise ownership and unsent notebook operations.
/// No collection row or scheduler field is written here.
public struct LingroveNotebookReviewStore {
    public let core: DatabaseCore

    private static let columns = "workspace_id,enrollment_id,notebook_id,entry_id,sense_id,status,revision,created_at,updated_at"

    public func load(workspaceId: String) throws -> [LingroveNotebookReviewEnrollment] {
        try self.core.query(sql: "SELECT \(Self.columns) FROM notebook_review_enrollments WHERE workspace_id=? ORDER BY created_at,enrollment_id",
            values: [.text(workspaceId)], map: self.decode)
    }

    public func find(workspaceId: String, id: UUID) throws -> LingroveNotebookReviewEnrollment? {
        try self.core.query(sql: "SELECT \(Self.columns) FROM notebook_review_enrollments WHERE workspace_id=? AND enrollment_id=?",
            values: [.text(workspaceId), .text(id.uuidString)], map: self.decode).first
    }

    /// A merge may bring two previously enrolled senses together. Preserve both sets of
    /// exercises/progress and treat future participation changes as one resolved sense group.
    public func matching(
        source: LingroveNotebookCardSource, snapshot: LingroveNotebookSnapshot
    ) throws -> [LingroveNotebookReviewEnrollment] {
        guard let selection = LingroveNotebookCardMaterial.resolvedSelection(source: source, snapshot: snapshot) else {
            throw VocabularyError.editConflict
        }
        return try self.load(workspaceId: source.workspaceId).filter {
            LingroveNotebookCardMaterial.resolvedSelection(source: $0.source, snapshot: snapshot) == selection
        }
    }

    public func insert(source: LingroveNotebookCardSource, now: String) throws -> LingroveNotebookReviewEnrollment {
        let value = LingroveNotebookReviewEnrollment(id: LingroveNotebookCardMaterial.stableID("enrollment", workspace: source.workspaceId, sense: source.senseId), workspaceId: source.workspaceId,
            notebookId: source.notebookId, entryId: source.entryId, senseId: source.senseId,
            status: .active, revision: 1, createdAt: now, updatedAt: now)
        try self.core.execute(sql: "INSERT INTO notebook_review_enrollments(\(Self.columns)) VALUES(?,?,?,?,?,?,?,?,?)",
            values: [.text(value.workspaceId), .text(value.id.uuidString), .text(value.notebookId.uuidString),
                .text(value.entryId.uuidString), .text(value.senseId.uuidString), .text(value.status.rawValue),
                .integer(1), .text(now), .text(now)])
        try self.record(value, baseRevision: 0)
        return value
    }

    public func update(
        _ expected: LingroveNotebookReviewEnrollment, status: LingroveNotebookReviewStatus,
        changingExercises: Bool = false
    ) throws -> LingroveNotebookReviewEnrollment {
        guard try self.find(workspaceId: expected.workspaceId, id: expected.id) == expected else { throw VocabularyError.editConflict }
        guard expected.status != status || changingExercises else { return expected }
        guard expected.revision < UInt64(Int64.max) else { throw VocabularyError.editConflict }
        let now = max(nowIsoTimestamp(), formatIsoTimestamp(date: (parseIsoTimestamp(value: expected.updatedAt) ?? .distantPast).addingTimeInterval(0.001)))
        let next = LingroveNotebookReviewEnrollment(id: expected.id, workspaceId: expected.workspaceId,
            notebookId: expected.notebookId, entryId: expected.entryId, senseId: expected.senseId,
            status: status, revision: expected.revision + 1, createdAt: expected.createdAt, updatedAt: now)
        let changed = try self.core.execute(sql: """
            UPDATE notebook_review_enrollments SET status=?,revision=?,updated_at=?
            WHERE workspace_id=? AND enrollment_id=? AND revision=?
            """, values: [.text(status.rawValue), .integer(Int64(next.revision)), .text(now),
                .text(expected.workspaceId), .text(expected.id.uuidString), .integer(Int64(expected.revision))])
        guard changed == 1 else { throw VocabularyError.editConflict }
        try self.record(next, baseRevision: expected.revision)
        return next
    }

    public func attach(
        cardId: String, linkId: UUID, to enrollment: LingroveNotebookReviewEnrollment, now: String
    ) throws -> LingroveNotebookReviewEnrollment {
        try self.core.execute(sql: """
            INSERT INTO notebook_review_exercises(workspace_id,enrollment_id,card_id,link_id,created_at) VALUES(?,?,?,?,?)
            """, values: [.text(enrollment.workspaceId), .text(enrollment.id.uuidString), .text(cardId), .text(linkId.uuidString), .text(now)])
        // Exercise membership is part of enrollment CAS and its pending operation. A new
        // replacement Card must not exist only in an unjournaled relationship table.
        return try self.update(enrollment, status: enrollment.status, changingExercises: true)
    }

    public func exercises(_ enrollment: LingroveNotebookReviewEnrollment) throws -> [LingroveNotebookReviewExercise] {
        try self.core.query(sql: """
            SELECT card_id,link_id,created_at FROM notebook_review_exercises
            WHERE workspace_id=? AND enrollment_id=? ORDER BY created_at,card_id
            """, values: [.text(enrollment.workspaceId), .text(enrollment.id.uuidString)]) {
            guard let linkId = UUID(uuidString: DatabaseCore.columnText(statement: $0, index: 1)) else { throw VocabularyError.invalidArchive }
            return .init(enrollmentId: enrollment.id, cardId: DatabaseCore.columnText(statement: $0, index: 0),
                linkId: linkId, createdAt: DatabaseCore.columnText(statement: $0, index: 2))
        }
    }

    public func hasLiveExercise(_ enrollments: [LingroveNotebookReviewEnrollment]) throws -> Bool {
        for enrollment in enrollments {
            if try self.core.scalarInt(sql: """
                SELECT EXISTS(SELECT 1 FROM notebook_review_exercises AS exercise
                JOIN cards ON cards.workspace_id=exercise.workspace_id AND cards.card_id=exercise.card_id
                WHERE exercise.workspace_id=? AND exercise.enrollment_id=? AND cards.deleted_at IS NULL)
                """, values: [.text(enrollment.workspaceId), .text(enrollment.id.uuidString)]) != 0 { return true }
        }
        return false
    }

    /// The existing public-ID repair transaction may re-key an exercise after sync conflict.
    /// Keep the enrollment's mapping and pending snapshot aligned without changing progress.
    public func rewriteCardId(workspaceId: String, from oldId: String, to newId: String) throws {
        let owners = try self.core.query(sql: "SELECT enrollment_id FROM notebook_review_exercises WHERE workspace_id=? AND card_id=?",
            values: [.text(workspaceId), .text(oldId)]) { DatabaseCore.columnText(statement: $0, index: 0) }
        for owner in owners {
            guard let id = UUID(uuidString: owner), let enrollment = try self.find(workspaceId: workspaceId, id: id) else {
                throw VocabularyError.invalidArchive
            }
            try self.core.execute(sql: "UPDATE notebook_review_exercises SET card_id=? WHERE workspace_id=? AND card_id=?",
                values: [.text(newId), .text(workspaceId), .text(oldId)])
            _ = try self.update(enrollment, status: enrollment.status, changingExercises: true)
        }
    }

    /// An uncertain UI result must not reactivate a later pause/withdrawal. Replay returns the
    /// current values for the original result IDs without executing the old intent again.
    public func replay(workspaceId: String, requestId: UUID, fingerprint: String) throws -> [LingroveNotebookReviewEnrollment]? {
        let rows = try self.core.query(sql: "SELECT fingerprint,enrollment_ids_json FROM notebook_review_requests WHERE workspace_id=? AND request_id=?",
            values: [.text(workspaceId), .text(requestId.uuidString)]) {
            (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1))
        }
        guard let row = rows.first else { return nil }
        guard row.0 == fingerprint else { throw VocabularyError.editConflict }
        let ids = try self.core.decoder.decode([UUID].self, from: Data(row.1.utf8))
        return try ids.map {
            guard let enrollment = try self.find(workspaceId: workspaceId, id: $0) else { throw VocabularyError.invalidArchive }
            return enrollment
        }
    }

    public func recordRequest(
        workspaceId: String, requestId: UUID, fingerprint: String, result: [LingroveNotebookReviewEnrollment]
    ) throws {
        try self.core.execute(sql: """
            INSERT INTO notebook_review_requests(workspace_id,request_id,fingerprint,enrollment_ids_json,created_at) VALUES(?,?,?,?,?)
            """, values: [.text(workspaceId), .text(requestId.uuidString), .text(fingerprint),
                .text(try self.core.encodeJsonString(value: result.map(\.id))), .text(nowIsoTimestamp())])
    }

    public func record(_ value: LingroveNotebookReviewEnrollment, baseRevision: UInt64) throws {
        try self.core.execute(sql: """
            INSERT INTO notebook_review_operations(operation_id,workspace_id,enrollment_id,base_revision,revision,payload_json,created_at)
            VALUES(?,?,?,?,?,?,?)
            """, values: [.text(UUID().uuidString.lowercased()), .text(value.workspaceId), .text(value.id.uuidString),
                .integer(Int64(baseRevision)), .integer(Int64(value.revision)),
                .text(try self.core.encodeJsonString(value: NotebookReviewPendingValue(enrollment: value,
                    exercises: self.exercises(value)))), .text(value.updatedAt)])
    }

    private func decode(_ statement: OpaquePointer) throws -> LingroveNotebookReviewEnrollment {
        func uuid(_ index: Int32) throws -> UUID {
            guard let id = UUID(uuidString: DatabaseCore.columnText(statement: statement, index: index)) else { throw VocabularyError.invalidArchive }
            return id
        }
        let revision = DatabaseCore.columnInt64(statement: statement, index: 6)
        guard sqlite3_column_type(statement, 6) == SQLITE_INTEGER, revision > 0,
              let status = LingroveNotebookReviewStatus(rawValue: DatabaseCore.columnText(statement: statement, index: 5)) else {
            throw VocabularyError.invalidArchive
        }
        return .init(id: try uuid(1), workspaceId: DatabaseCore.columnText(statement: statement, index: 0),
            notebookId: try uuid(2), entryId: try uuid(3), senseId: try uuid(4), status: status, revision: UInt64(revision),
            createdAt: DatabaseCore.columnText(statement: statement, index: 7), updatedAt: DatabaseCore.columnText(statement: statement, index: 8))
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}

/// The local pending snapshot captures participation and its exercise set at the same revision.
/// It is not the remote wire format: server versions and atomic change groups are added by sync.
private struct NotebookReviewPendingValue: Encodable {
    let enrollment: LingroveNotebookReviewEnrollment
    let exercises: [LingroveNotebookReviewExercise]
}
