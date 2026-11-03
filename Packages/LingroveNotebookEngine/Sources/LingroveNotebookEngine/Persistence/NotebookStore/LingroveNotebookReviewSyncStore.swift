import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// This adapter borrows notebook's account generation and SQLite transaction. It never
/// releases a hold into generic sync: acknowledgment removes only the exact immutable rows
/// sent, then remote state is installed with a pending-local overlay and one durable cursor.
public struct LingroveNotebookReviewSyncStore {
    public let core: DatabaseCore
    private struct Pending: Decodable {
    let enrollment: LingroveNotebookReviewEnrollment
}
    private struct Exercise: Decodable {
    let enrollmentId: UUID
    let link: LingroveNotebookCardLink
    let card: Card
    let scheduleOperationId: String?
}

    public func request(_ binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookReviewRequest {
        try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let workspace = binding.scope.workspaceID.uuidString.lowercased()
            let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
            guard let installation = UUID(uuidString: settings.installationId) else { throw LingroveNotebookNetworkError.identityMismatch }
            let pendingMedia = try LingroveNotebookReviewMediaStore(core: core).pending(workspaceID: workspace)
            if !pendingMedia.isEmpty {
                // A finite media envelope is acknowledged before dependent plans/Cards. Keeping
                // this independent avoids a large recording starving every later Card operation.
                let value = LingroveNotebookReviewRequest(protocolVersion: 2, notebookId: binding.scope.notebookID,
                    replicaId: binding.scope.replicaID, installationId: installation, afterSequence: try cursor(workspace),
                    sourceSequence: "0", enrollments: [], links: [], operations: [], undos: [], confirmations: [], media: pendingMedia)
                guard try core.encoder.encode(value).count <= 7 * 1024 * 1024 else { throw LingroveNotebookNetworkError.replyTooLarge }
                return value
            }
            let richProtocol = try core.scalarInt(sql: "SELECT EXISTS(SELECT 1 FROM notebook_card_links WHERE workspace_id=? AND material_plan_json IS NOT NULL)", values: [.text(workspace)]) != 0
            let enrollments = try core.query(sql: """
                SELECT operation_id,payload_json FROM (SELECT operation_id,payload_json,created_at,ROW_NUMBER() OVER(PARTITION BY enrollment_id ORDER BY revision DESC) ordinal
                FROM notebook_review_operations WHERE workspace_id=?) WHERE ordinal=1 ORDER BY created_at,operation_id LIMIT 200
                """, values: [.text(workspace)]) { row in
                let value = try core.decoder.decode(Pending.self, from: Data(DatabaseCore.columnText(statement: row, index: 1).utf8)).enrollment
                return LingroveNotebookReviewRequest.Enrollment(operationId: DatabaseCore.columnText(statement: row, index: 0), value: remote(value, book: binding.scope.notebookID))
            }
            let sentEnrollmentIDs = Set(enrollments.map { $0.value.id })
            let links = try core.query(sql: """
                SELECT operation.operation_id,exercise.enrollment_id,operation.payload_json
                FROM notebook_card_link_operations operation JOIN notebook_review_exercises exercise
                ON exercise.workspace_id=operation.workspace_id AND exercise.link_id=operation.link_id
                WHERE operation.workspace_id=? AND operation.revision=(SELECT MAX(other.revision) FROM notebook_card_link_operations other WHERE other.workspace_id=operation.workspace_id AND other.link_id=operation.link_id)
                ORDER BY operation.created_at,operation.operation_id
                """, values: [.text(workspace)]) { row in
                guard let owner = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)) else { throw LingroveNotebookNetworkError.invalidReply }
                let link = try core.decoder.decode(LingroveNotebookCardLink.self, from: Data(DatabaseCore.columnText(statement: row, index: 2).utf8))
                return LingroveNotebookReviewRequest.Link(operationId: DatabaseCore.columnText(statement: row, index: 0), enrollmentId: owner, value: remote(link, book: binding.scope.notebookID))
            }
            let admittedLinks = try links.filter { item in
                if sentEnrollmentIDs.contains(item.enrollmentId) { return true }
                return try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_operations WHERE workspace_id=? AND enrollment_id=?", values: [.text(workspace), .text(item.enrollmentId.uuidString)]) == 0
            }.prefix(200)
            let sentCardIDs = Set(admittedLinks.map { $0.value.cardId })
            // Metadata precedes Cards. A stable operation prefix preserves creation before
            // event publication; undo admission below waits for both of its rating dependencies.
            let operations = try core.query(sql: """
                SELECT operation_id,entity_type,entity_id,operation_type,payload_json,client_updated_at,is_initial_create,review_schedule_impact
                FROM notebook_held_card_operations WHERE workspace_id=? AND subject_card_id IN
                (SELECT card_id FROM notebook_review_exercises WHERE workspace_id=?) ORDER BY created_at,rowid
                """, values: [.text(workspace), .text(workspace)]) { row in
                let stored = Data(DatabaseCore.columnText(statement: row, index: 4).utf8)
                // Local outbox JSON omits nil columns. The existing typed wire encoder owns
                // explicit JSON nulls required by the backend's current Card snapshot contract.
                let wire = DatabaseCore.columnText(statement: row, index: 1) == "card"
                    ? try core.encoder.encode(core.decoder.decode(CardSyncPayload.self, from: stored)) : stored
                let payload = try core.decoder.decode(VocabularyWireJSON.self, from: wire)
                let value = VocabularyWireJSON.object(["operationId":.string(DatabaseCore.columnText(statement: row, index: 0)),
                    "entityType":.string(DatabaseCore.columnText(statement: row, index: 1)), "entityId":.string(DatabaseCore.columnText(statement: row, index: 2)),
                    "action":.string(DatabaseCore.columnText(statement: row, index: 3)), "payload":payload,
                    "clientUpdatedAt":.string(DatabaseCore.columnText(statement: row, index: 5))])
                return LingroveNotebookReviewRequest.Operation(operation: value, initial: DatabaseCore.columnInt64(statement: row, index: 6) != 0, schedule: DatabaseCore.columnInt64(statement: row, index: 7) != 0)
            }
            let admittedOperations = try operations.filter { item in
                guard case let .object(fields) = item.operation, case let .object(payload)? = fields["payload"], case let .string(cardID)? = payload["cardId"] else { return false }
                if sentCardIDs.contains(cardID) { return true }
                return try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_card_link_operations operation JOIN notebook_review_exercises exercise ON exercise.workspace_id=operation.workspace_id AND exercise.link_id=operation.link_id WHERE operation.workspace_id=? AND exercise.card_id=?", values: [.text(workspace), .text(cardID)]) == 0
            }
            let undos = try core.query(sql: "SELECT undo_id,card_id,event_id,target_operation_id,previous_card_json,created_at FROM notebook_review_undo WHERE workspace_id=? AND pending=1 ORDER BY created_at LIMIT 100", values: [.text(workspace)]) { row in
                LingroveNotebookReviewUndo(undoId: DatabaseCore.columnText(statement: row, index: 0), cardId: DatabaseCore.columnText(statement: row, index: 1),
                    eventId: DatabaseCore.columnText(statement: row, index: 2), targetOperationId: DatabaseCore.columnText(statement: row, index: 3),
                    previousCard: try core.decoder.decode(Card.self, from: Data(DatabaseCore.columnText(statement: row, index: 4).utf8)), createdAt: DatabaseCore.columnText(statement: row, index: 5))
            }
            let sentOperationIDs = Set(admittedOperations.compactMap { item -> String? in
                guard case let .object(fields) = item.operation, case let .string(id)? = fields["operationId"] else { return nil }; return id
            })
            let admittedUndos = try undos.filter { undo in
                let dependencies = try core.query(sql: "SELECT operation_id FROM notebook_held_card_operations WHERE workspace_id=? AND (operation_id=? OR (entity_type='review_event' AND entity_id=?))", values: [.text(workspace), .text(undo.targetOperationId), .text(undo.eventId)]) { DatabaseCore.columnText(statement: $0, index: 0) }
                return dependencies.allSatisfy { sentOperationIDs.contains($0) }
            }
            let localBook = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspace).notebookId
            let sourceSequence = try LingroveNotebookSyncStore(core: core).confirmedShadowInTransaction(binding: binding, localNotebookID: localBook)?.sequence.rawValue ?? "0"
            let confirmations = try core.query(sql: """
                SELECT card.card_id,link.revision,card.last_operation_id FROM cards card
                JOIN notebook_review_exercises exercise ON exercise.workspace_id=card.workspace_id AND exercise.card_id=card.card_id
                JOIN notebook_card_links link ON link.workspace_id=exercise.workspace_id AND link.link_id=exercise.link_id
                LEFT JOIN notebook_review_material_confirmations confirmed ON confirmed.workspace_id=card.workspace_id AND confirmed.card_id=card.card_id
                WHERE card.workspace_id=? AND card.deleted_at IS NULL AND link.deleted_at IS NULL
                AND (confirmed.source_sequence IS NULL OR confirmed.source_sequence<>? OR confirmed.link_revision<>link.revision OR confirmed.card_operation_id<>card.last_operation_id)
                AND NOT EXISTS(SELECT 1 FROM notebook_card_link_operations pending WHERE pending.workspace_id=card.workspace_id AND pending.link_id=link.link_id)
                AND NOT EXISTS(SELECT 1 FROM notebook_held_card_operations pending WHERE pending.workspace_id=card.workspace_id AND pending.subject_card_id=card.card_id)
                ORDER BY card.card_id LIMIT 200
                """, values: [.text(workspace), .text(sourceSequence)]) {
                LingroveNotebookReviewRequest.Confirmation(cardId: DatabaseCore.columnText(statement: $0, index: 0), linkRevision: UInt64(DatabaseCore.columnInt64(statement: $0, index: 1)), cardOperationId: DatabaseCore.columnText(statement: $0, index: 2))
            }
            let adoptions = try core.query(sql: "SELECT payload_json FROM notebook_review_history_adoptions WHERE workspace_id=? AND pending=1 ORDER BY operation_id",
                values: [.text(workspace)]) { try core.decoder.decode(LingroveNotebookReviewRequest.HistoryAdoption.self,
                    from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8)) }
            return try bounded(.init(protocolVersion: richProtocol ? 2 : 1, notebookId: binding.scope.notebookID, replicaId: binding.scope.replicaID, installationId: installation,
                afterSequence: try cursor(workspace), sourceSequence: sourceSequence, enrollments: enrollments, links: Array(admittedLinks), operations: Array(admittedOperations), undos: admittedUndos, confirmations: confirmations, historyAdoptions: adoptions))
        }
    }

    public func apply(_ response: LingroveNotebookReviewResponse, request: LingroveNotebookReviewRequest, binding: LingroveNotebookWindowBinding) throws {
        try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let workspace = binding.scope.workspaceID.uuidString.lowercased()
            guard [1, 2].contains(request.protocolVersion), (response.protocolVersion == request.protocolVersion || request.protocolVersion == 1 && response.protocolVersion == 2), response.notebookId == binding.scope.notebookID, response.replicaId == binding.scope.replicaID,
                  try cursor(workspace) == request.afterSequence, response.afterSequence >= request.afterSequence else { throw LingroveNotebookNetworkError.invalidReply }
            let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspace)
            let sentMedia = request.media ?? [], receivedMedia = response.media ?? []
            let acknowledgedMedia = response.acknowledgedMedia ?? []
            guard response.protocolVersion == 2 || (sentMedia.isEmpty && receivedMedia.isEmpty && acknowledgedMedia.isEmpty),
                  Set(acknowledgedMedia) == Set(sentMedia.map { $0.reference.digest }),
                  Set(acknowledgedMedia).count == acknowledgedMedia.count,
                  receivedMedia.count <= 128, receivedMedia.reduce(0, { $0 + $1.reference.byteCount }) <= 16 * 1024 * 1024 else {
                throw LingroveNotebookNetworkError.invalidReply
            }
            let resources = LingroveNotebookReviewMediaStore(core: core)
            for prepared in receivedMedia { try resources.insert(prepared, workspaceID: workspace, acknowledged: true) }
            try resources.acknowledge(acknowledgedMedia, workspaceID: workspace)
            guard Set(response.confirmed).isSubset(of: Set(request.confirmations.map(\.cardId))) else { throw LingroveNotebookNetworkError.invalidReply }
            for value in request.confirmations where response.confirmed.contains(value.cardId) {
                try core.execute(sql: "INSERT INTO notebook_review_material_confirmations(workspace_id,card_id,source_sequence,link_revision,card_operation_id) VALUES(?,?,?,?,?) ON CONFLICT(workspace_id,card_id) DO UPDATE SET source_sequence=excluded.source_sequence,link_revision=excluded.link_revision,card_operation_id=excluded.card_operation_id", values: [.text(workspace), .text(value.cardId), .text(request.sourceSequence), .integer(Int64(value.linkRevision)), .text(value.cardOperationId)])
            }
            let sent = Set(request.enrollments.map(\.operationId) + request.links.map(\.operationId) + request.operations.compactMap {
                if case let .object(fields) = $0.operation, case let .string(id)? = fields["operationId"] { return id }; return nil
            } + request.undos.map(\.undoId) + request.historyAdoptions.map(\.operationId))
            guard Set(response.acknowledged) == sent else { throw LingroveNotebookNetworkError.invalidReply }
            for id in response.acknowledged {
                for table in ["notebook_review_operations", "notebook_card_link_operations", "notebook_held_card_operations"] {
                    try core.execute(sql: "DELETE FROM \(table) WHERE workspace_id=? AND operation_id=?", values: [.text(workspace), .text(id)])
                }
                try core.execute(sql: "UPDATE notebook_review_history_adoptions SET pending=0 WHERE workspace_id=? AND operation_id=?", values: [.text(workspace), .text(id)])
                try core.execute(sql: "UPDATE notebook_review_undo SET pending=0 WHERE workspace_id=? AND undo_id=?", values: [.text(workspace), .text(id)])
            }
            var prior = request.afterSequence
            for item in response.changes {
                guard let sequence = Int64(item.sequence), sequence > prior, sequence <= response.afterSequence else { throw LingroveNotebookNetworkError.invalidReply }
                prior = sequence
                let data = try core.encoder.encode(item.value)
                switch item.kind {
                case "enrollment":
                    let value = try core.decoder.decode(LingroveNotebookReviewEnrollment.self, from: data)
                    guard value.workspaceId == workspace, value.notebookId == binding.scope.notebookID else { throw LingroveNotebookNetworkError.identityMismatch }
                    if try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_operations WHERE workspace_id=? AND enrollment_id=?", values: [.text(workspace), .text(value.id.uuidString)]) == 0 {
                        try core.execute(sql: """
                            INSERT INTO notebook_review_enrollments(workspace_id,enrollment_id,notebook_id,entry_id,sense_id,status,revision,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)
                            ON CONFLICT(workspace_id,enrollment_id) DO UPDATE SET status=excluded.status,revision=excluded.revision,updated_at=excluded.updated_at
                            """, values: [.text(workspace), .text(value.id.uuidString), .text(local.notebookId.uuidString), .text(value.entryId.uuidString), .text(value.senseId.uuidString),
                                .text(value.status.rawValue), .integer(Int64(value.revision)), .text(value.createdAt), .text(value.updatedAt)])
                    }
                case "exercise":
                    let value = try core.decoder.decode(Exercise.self, from: data)
                    guard value.card.workspaceId == workspace, value.link.source.workspaceId == workspace,
                          value.link.source.notebookId == binding.scope.notebookID, value.link.cardId == value.card.cardId else { throw LingroveNotebookNetworkError.identityMismatch }
                    let link = remote(value.link, book: local.notebookId, sourceRevision: local.revision)
                    if let plan = link.materialPlan {
                        guard response.protocolVersion == 2, plan.exampleID == link.source.exampleId else { throw LingroveNotebookNetworkError.invalidReply }
                        try resources.register(plan: plan, source: link.source, snapshot: local, supplied: [])
                    }
                    let pendingLink = try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_card_link_operations WHERE workspace_id=? AND link_id=?", values: [.text(workspace), .text(link.id.uuidString)])
                    if pendingLink == 0 {
                        try core.execute(sql: """
                            INSERT INTO notebook_card_links(workspace_id,link_id,notebook_id,entry_id,sense_id,example_id,card_id,generated_content_json,source_revision,creation_fingerprint,revision,created_at,updated_at,deleted_at,allows_unavailable_material,material_plan_json)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(workspace_id,link_id) DO UPDATE SET example_id=excluded.example_id,generated_content_json=excluded.generated_content_json,
                            source_revision=excluded.source_revision,revision=excluded.revision,updated_at=excluded.updated_at,deleted_at=excluded.deleted_at,allows_unavailable_material=excluded.allows_unavailable_material,material_plan_json=excluded.material_plan_json
                            """, values: [.text(workspace), .text(link.id.uuidString), .text(local.notebookId.uuidString), .text(link.source.entryId.uuidString), .text(link.source.senseId.uuidString),
                                link.source.exampleId.map { .text($0.uuidString) } ?? .null, .text(link.cardId), try link.generatedContent.map { .text(try core.encodeJsonString(value: $0)) } ?? .null,
                                .integer(Int64(link.sourceRevision)), .text(link.creationFingerprint), .integer(Int64(link.revision)), .text(link.createdAt), .text(link.updatedAt), link.deletedAt.map(SQLiteValue.text) ?? .null, .integer(link.allowsUnavailableMaterial ? 1 : 0), try link.materialPlan.map { .text(try core.encodeJsonString(value: $0)) } ?? .null])
                    }
                    try core.execute(sql: "INSERT INTO notebook_review_exercises(workspace_id,enrollment_id,card_id,link_id,created_at) VALUES(?,?,?,?,?) ON CONFLICT(workspace_id,card_id) DO NOTHING",
                        values: [.text(workspace), .text(value.enrollmentId.uuidString), .text(value.card.cardId), .text(link.id.uuidString), .text(link.createdAt)])
                    try core.execute(sql: "INSERT INTO notebook_card_sync_holds(workspace_id,card_id,notebook_id,creation_operation_id,created_at) VALUES(?,?,?,?,?) ON CONFLICT(workspace_id,card_id) DO NOTHING",
                        values: [.text(workspace), .text(value.card.cardId), .text(local.notebookId.uuidString), .text(value.card.lastOperationId), .text(value.card.createdAt)])
                    if try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_held_card_operations WHERE workspace_id=? AND subject_card_id=?", values: [.text(workspace), .text(value.card.cardId)]) == 0 {
                        let pendingUndo = try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_undo WHERE workspace_id=? AND card_id=? AND pending=1", values: [.text(workspace), .text(value.card.cardId)])
                        if pendingUndo == 0 {
                            try SyncApplier(core: core).upsertRemoteCard(workspaceId: workspace, card: value.card, cardStore: CardStore(core: core))
                            try core.execute(sql: "INSERT INTO notebook_review_schedule_heads(workspace_id,card_id,operation_id) VALUES(?,?,?) ON CONFLICT(workspace_id,card_id) DO UPDATE SET operation_id=excluded.operation_id", values: [.text(workspace), .text(value.card.cardId), value.scheduleOperationId.map(SQLiteValue.text) ?? .null])
                        }
                    }
                case "event":
                    let event = try core.decoder.decode(ReviewEvent.self, from: data)
                    guard event.workspaceId == workspace else { throw LingroveNotebookNetworkError.identityMismatch }
                    try SyncApplier(core: core).insertRemoteReviewEvent(workspaceId: workspace, reviewEvent: event)
                case "undo":
                    let value = try core.decoder.decode(LingroveNotebookReviewUndo.self, from: data)
                    try core.execute(sql: "INSERT INTO notebook_review_undo(workspace_id,undo_id,card_id,event_id,target_operation_id,previous_card_json,created_at,pending) VALUES(?,?,?,?,?,?,?,0) ON CONFLICT DO NOTHING",
                        values: [.text(workspace), .text(value.undoId), .text(value.cardId), .text(value.eventId), .text(value.targetOperationId), .text(try core.encodeJsonString(value: value.previousCard)), .text(value.createdAt)])
                default: throw LingroveNotebookNetworkError.invalidReply
                }
            }
            try core.execute(sql: "INSERT INTO notebook_review_sync_state(workspace_id,after_sequence) VALUES(?,?) ON CONFLICT(workspace_id) DO UPDATE SET after_sequence=excluded.after_sequence", values: [.text(workspace), .integer(response.afterSequence)])
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(local)
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
        }
    }

    /// Bound encoded bytes as well as row counts. A prefix preserves initial-create/event
    /// dependencies; metadata may publish first, with its Card arriving in the next batch.
    private func bounded(_ input: LingroveNotebookReviewRequest) throws -> LingroveNotebookReviewRequest {
        var links = input.links, operations = Array(input.operations.prefix(400)), undos = input.undos
        while true {
            let selectedIDs = Set(operations.compactMap { if case let .object(f) = $0.operation, case let .string(id)? = f["operationId"] { return id }; return nil })
            func id(_ op: LingroveNotebookReviewRequest.Operation) -> String? {
                if case let .object(f) = op.operation, case let .string(id)? = f["operationId"] { return id }; return nil
            }
            func text(_ json: VocabularyWireJSON?) -> String? {
                if case let .string(value)? = json { return value }; return nil
            }
            func eventKey(_ op: LingroveNotebookReviewRequest.Operation) -> String? {
                guard case let .object(f) = op.operation, case let .string(type)? = f["entityType"], case let .object(p)? = f["payload"],
                      case let .string(card)? = p["cardId"] else { return nil }
                if type == "review_event", case let .string(date)? = p["reviewedAtClient"] { return card + "|" + date }
                if type == "card", op.schedule, !op.initial, case let .string(date)? = f["clientUpdatedAt"], text(p["fsrsLastReviewedAt"]) == date { return card + "|" + date }
                return nil
            }
            let linkedCards = Set(links.map { $0.value.cardId })
            let pendingLinkCards = Set(input.links.map { $0.value.cardId })
            let paired = operations.filter { op in
                // Byte trimming can postpone metadata. Its Card and events must
                // wait too; the server cannot accept a graph with no owner yet.
                if case let .object(f) = op.operation, case let .object(p)? = f["payload"], let card = text(p["cardId"]),
                   pendingLinkCards.contains(card), !linkedCards.contains(card) { return false }
                guard let key = eventKey(op) else { return true }
                return input.operations.filter { eventKey($0) == key }.allSatisfy { id($0).map(selectedIDs.contains) ?? false }
            }
            let retainedIDs = Set(paired.compactMap(id))
            let allIDs = Set(input.operations.compactMap(id))
            let safeUndos = undos.filter { undo in
                // The event entity ID differs from its operation ID.
                let dependencies = input.operations.filter { op in
                    guard case let .object(f) = op.operation else { return false }
                    return text(f["operationId"]) == undo.targetOperationId || text(f["entityId"]) == undo.eventId
                }.compactMap(id)
                return dependencies.allSatisfy(retainedIDs.contains) || dependencies.allSatisfy { !allIDs.contains($0) }
            }
            let adoptions = input.historyAdoptions.filter { adoption in links.contains { $0.value.cardId == adoption.cardId } }
            let importedOwners = Set(input.historyAdoptions.map(\.enrollmentId))
            let selectedOwners = Set(adoptions.map(\.enrollmentId))
            let enrollments = input.enrollments.filter { !importedOwners.contains($0.value.id) || selectedOwners.contains($0.value.id) }
            if paired.isEmpty && !input.operations.isEmpty && links.isEmpty && enrollments.isEmpty && safeUndos.isEmpty && input.confirmations.isEmpty {
                throw LingroveNotebookNetworkError.replyTooLarge
            }
            let next = LingroveNotebookReviewRequest(protocolVersion: input.protocolVersion, notebookId: input.notebookId,
                replicaId: input.replicaId, installationId: input.installationId, afterSequence: input.afterSequence,
                sourceSequence: input.sourceSequence, enrollments: enrollments, links: links, operations: paired, undos: safeUndos, confirmations: input.confirmations,
                historyAdoptions: adoptions)
            if try core.encoder.encode(next).count <= 7 * 1024 * 1024 { return next }
            if !undos.isEmpty { undos.removeLast() }
            else if !operations.isEmpty { operations.removeLast() }
            else if !links.isEmpty { links.removeLast() }
            else { throw LingroveNotebookNetworkError.replyTooLarge }
        }
    }

    public func cursor(_ workspace: String) throws -> Int64 {
        Int64(try core.scalarInt(sql: "SELECT COALESCE((SELECT after_sequence FROM notebook_review_sync_state WHERE workspace_id=?),0)", values: [.text(workspace)]))
    }
    private func remote(_ value: LingroveNotebookReviewEnrollment, book: UUID) -> LingroveNotebookReviewEnrollment {
        .init(id: value.id, workspaceId: value.workspaceId, notebookId: book, entryId: value.entryId, senseId: value.senseId,
            status: value.status, revision: value.revision, createdAt: value.createdAt, updatedAt: value.updatedAt)
    }
    private func remote(_ value: LingroveNotebookCardLink, book: UUID, sourceRevision: UInt64? = nil) -> LingroveNotebookCardLink {
        .init(id: value.id, source: .init(workspaceId: value.source.workspaceId, notebookId: book, entryId: value.source.entryId,
            senseId: value.source.senseId, exampleId: value.source.exampleId), cardId: value.cardId, generatedContent: value.generatedContent,
            sourceRevision: sourceRevision ?? value.sourceRevision, creationFingerprint: value.creationFingerprint, revision: value.revision,
            createdAt: value.createdAt, updatedAt: value.updatedAt, deletedAt: value.deletedAt, allowsUnavailableMaterial: value.allowsUnavailableMaterial, materialPlan: value.materialPlan)
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
