import Foundation
import LingroveNotebook
import LingroveNotebookStorage

/// Host-private acknowledgements share the notebook writer, but never its public sync projection.
/// The key is global within this installation: reusing a completed request in another account is
/// a conflict, not a fresh capture. A receipt survives journal ACK and process restart; its saved
/// generation records provenance while the current command's generation fences every new write.
public struct LingroveNotebookCLIStore {
    public let core: DatabaseCore
    public static let maximumResultBytes = 32 * 1_024 * 1_024

    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_cli_receipts (
            request_key TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(request_key AS BLOB)) BETWEEN 1 AND 200),
            workspace_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            api_base_url TEXT NOT NULL,
            generation TEXT NOT NULL,
            fingerprint TEXT NOT NULL CHECK(length(fingerprint)=64),
            result_json TEXT NOT NULL CHECK(length(CAST(result_json AS BLOB)) BETWEEN 1 AND \(maximumResultBytes)),
            revision INTEGER NOT NULL CHECK(revision>0)
        );
        """
    public static let resetSQL = "DROP TABLE IF EXISTS notebook_cli_receipts;"

    public init(core: DatabaseCore) { self.core = core }

    /// Caller owns a transaction and has validated its current saved scope. The owner stamp is
    /// read from durable account metadata; no CLI input can select a different business owner.
    public func receiptInTransaction(key: String, scope: LingroveNotebookSnapshot) throws -> VocabularyCLIReceipt? {
        let owner = try ownerInTransaction(scope)
        let rows = try core.query(sql: """
            SELECT workspace_id,notebook_id,owner_user_id,api_base_url,fingerprint,result_json
            FROM notebook_cli_receipts WHERE request_key=?
            """, values: [.text(key)]) { row -> (String, String, String, String, String, String) in
                (DatabaseCore.columnText(statement: row, index: 0), DatabaseCore.columnText(statement: row, index: 1),
                 DatabaseCore.columnText(statement: row, index: 2), DatabaseCore.columnText(statement: row, index: 3),
                 DatabaseCore.columnText(statement: row, index: 4), DatabaseCore.columnText(statement: row, index: 5))
            }
        guard let row = rows.first else { return nil }
        guard row.0 == scope.workspaceId, row.1 == scope.notebookId.uuidString,
              row.2.utf8.elementsEqual(owner.user.utf8), row.3.utf8.elementsEqual(owner.endpoint.utf8) else {
            throw VocabularyError.editConflict
        }
        return .init(key: key, fingerprint: row.4, result: Data(row.5.utf8))
    }

    func insertInTransaction(_ receipt: VocabularyCLIReceipt, scope: LingroveNotebookSnapshot) throws {
        guard (1...200).contains(receipt.key.utf8.count), receipt.fingerprint.utf8.count == 64,
              receipt.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...Self.maximumResultBytes).contains(receipt.result.count),
              let result = String(data: receipt.result, encoding: .utf8),
              (try? JSONSerialization.jsonObject(with: receipt.result)) != nil else { throw VocabularyError.invalidContent }
        let owner = try ownerInTransaction(scope)
        try core.execute(sql: """
            INSERT INTO notebook_cli_receipts(request_key,workspace_id,notebook_id,owner_user_id,api_base_url,generation,fingerprint,result_json,revision)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, values: [.text(receipt.key), .text(scope.workspaceId), .text(scope.notebookId.uuidString),
                .text(owner.user), .text(owner.endpoint), .text(scope.generation), .text(receipt.fingerprint),
                .text(result), .integer(Int64(scope.revision))])
    }

    private func ownerInTransaction(_ scope: LingroveNotebookSnapshot) throws -> (user: String, endpoint: String) {
        let rows = try core.query(sql: "SELECT owner_user_id,api_base_url FROM notebook_account_scopes WHERE workspace_id=?",
            values: [.text(scope.workspaceId)]) { row in
                (DatabaseCore.columnOptionalText(statement: row, index: 0) ?? "", DatabaseCore.columnText(statement: row, index: 1))
            }
        return rows.first ?? ("", "")
    }
}

/// A raced retry returns the immutable original acknowledgement as well as the current book.
/// No caller needs to reconstruct the first operation's generated IDs or revision from new state.
public nonisolated struct LingroveNotebookCLICommit: Sendable {
    public let snapshot: LingroveNotebookSnapshot
    public let receipt: VocabularyCLIReceipt
    public let replayed: Bool
}

extension LingroveNotebookEngine {
    public func notebookCLIReceipt(key: String, basedOn scope: LingroveNotebookSnapshot) throws -> VocabularyCLIReceipt? {
        try core.inReadTransaction {
            try requireCurrentScopeInTransaction(scope, requireRevision: false)
            return try LingroveNotebookCLIStore(core: core).receiptInTransaction(key: key, scope: scope)
        }
    }

    /// PNG staging grants no ownership. Inside one existing writer transaction, replay is checked
    /// before CAS, then the shared corpus writer and acknowledgement either both commit or roll back.
    public func saveNotebookCLI(_ document: VocabularyDocument, basedOn baseline: LingroveNotebookSnapshot,
        images: [String: Data], receipt: VocabularyCLIReceipt) throws -> LingroveNotebookCLICommit {
        let staged = try LingroveNotebookMediaStore(core: core).stageSuppliedImages(document: document, supplied: images)
        try Task.checkCancellation()
        return try core.inTransaction {
            try requireCurrentScopeInTransaction(baseline, requireRevision: false)
            let receipts = LingroveNotebookCLIStore(core: core)
            if let previous = try receipts.receiptInTransaction(key: receipt.key, scope: baseline) {
                guard previous.fingerprint == receipt.fingerprint else { throw VocabularyError.editConflict }
                return .init(snapshot: try lingroveNotebookStore.readSnapshot(workspaceId: baseline.workspaceId),
                    receipt: previous, replayed: true)
            }
            let saved = try lingroveNotebookStore.saveInTransaction(document, basedOn: baseline, restoringBackup: false,
                staged: staged, requireActiveWorkspace: true, operationId: UUID().uuidString.lowercased())
            try receipts.insertInTransaction(receipt, scope: saved)
            return .init(snapshot: saved, receipt: receipt, replayed: false)
        }
    }
}
