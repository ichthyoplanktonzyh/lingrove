import Foundation
import LingroveNotebook

/// A CLI page owns bounded summaries and a read fence. It cannot be passed to a writer as
/// complete material; the archive adds transport fields without loading a corpus snapshot.
public nonisolated struct NotebookSummaryRead: Sendable {
    public let fence: NotebookBrowseFence
    public let total: Int
    public let values: [NotebookToolJSON]
}

extension LingroveNotebookEngine {
    /// Canonical IDs provide deterministic pagination, without inventing a business ordinal
    /// for senses. Only the requested headwords and their first 50 sense summaries are read.
    public func readNotebookSummaryPage(language: String? = nil, limit: Int = 50, offset: Int = 0) throws -> NotebookSummaryRead {
        guard (1...200).contains(limit), offset >= 0,
              language == nil || language == "und" || LearningLanguage(rawValue: language ?? "") != nil else {
            throw VocabularyError.invalidContent
        }
        return try core.inReadTransaction {
            let fence = try browseFenceInTransaction(), workspace = fence.version.workspaceId
            let filter = "workspace_id=?" + (language == nil ? "" : " AND language=?")
            var arguments: [SQLiteValue] = [.text(workspace)]
            if let language { arguments.append(.text(language)) }
            let total = try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries WHERE \(filter)", values: arguments)
            let headers = try core.query(sql: """
                SELECT id,expression,language,json_extract(payload_json,'$.kind')
                FROM notebook_entries WHERE \(filter) ORDER BY id LIMIT ? OFFSET ?
                """, values: arguments + [.integer(Int64(limit)), .integer(Int64(offset))]) { row in
                (0..<4).map { DatabaseCore.columnText(statement: row, index: Int32($0)) }
            }
            let values = try headers.map { header -> NotebookToolJSON in
                try Task.checkCancellation()
                guard UUID(uuidString: header[0]) != nil, VocabularyEntry.Kind(rawValue: header[3]) != nil else {
                    throw VocabularyError.invalidArchive
                }
                let owner: [SQLiteValue] = [.text(workspace), .text(header[0])]
                let count = try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_senses WHERE workspace_id=? AND parent_id=?", values: owner)
                // ORDER BY id can make SQLite prefer a workspace-wide ID scan to avoid a
                // tiny sort. Pin the parent index so LIMIT never walks unrelated senses.
                let senses = try core.query(sql: """
                    SELECT s.id,s.meaning,(SELECT COUNT(*) FROM notebook_usages u
                        WHERE u.workspace_id=s.workspace_id AND u.sense_id=s.id AND u.status='accepted')
                    FROM notebook_senses s INDEXED BY notebook_senses_owner
                    WHERE s.workspace_id=? AND s.parent_id=? ORDER BY s.id LIMIT 50
                    """, values: owner) { row -> NotebookToolJSON in
                    let meaning = DatabaseCore.columnText(statement: row, index: 1)
                    return .object(["senseID": .string(DatabaseCore.columnText(statement: row, index: 0)),
                        "meaning": .string(Self.materialSummary(meaning)),
                        "meaningTruncated": .bool(meaning.unicodeScalars.prefix(201).count > 200),
                        "exampleCount": .integer(DatabaseCore.columnInt64(statement: row, index: 2))])
                }
                return .object(["entryID": .string(header[0]), "expression": .string(Self.materialSummary(header[1])),
                    "expressionTruncated": .bool(header[1].unicodeScalars.prefix(201).count > 200),
                    "language": .string(header[2]), "kind": .string(header[3]),
                    "senseCount": .integer(Int64(count)), "sensesTruncated": .bool(count > 50), "senses": .array(senses)])
            }
            return .init(fence: fence, total: total, values: values)
        }
    }

    private static func materialSummary(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(200)))
    }
}
