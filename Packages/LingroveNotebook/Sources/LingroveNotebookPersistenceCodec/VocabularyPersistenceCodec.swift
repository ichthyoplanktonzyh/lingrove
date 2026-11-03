import Foundation
import LingroveNotebook

/// A store borrows immutable rows from the codec without seeing its typed payload dispatcher.
/// Encoding a payload is explicit and lazy: the Mac diff still encodes only changed rows, rather
/// than rewriting every example when a single note changes. Equality compares saved values, so
/// dictionary/Set JSON order cannot manufacture a change after reopening another process.
public nonisolated struct VocabularyPersistenceRow: Equatable, Sendable {
    public struct Key: Hashable, Sendable {
        public let entity: VocabularyPersistenceEntity
        public let id: String

        public init(entity: VocabularyPersistenceEntity, id: String) {
            self.entity = entity
            self.id = id
        }
    }

    let record: VocabularyDatabaseRecord
    public var entity: VocabularyPersistenceEntity { record.table }
    public var id: String { record.id }
    public var parentID: String? { record.parentID }
    public var position: Int { record.position }
    public var key: Key { .init(entity: entity, id: id) }
    public var indexValues: [VocabularyPersistenceIndex: String?] {
        Dictionary(uniqueKeysWithValues: zip(entity.indexKeys, record.extra))
    }

    /// A database supplies one opaque JSON leaf plus its separately stored index values.
    /// Keep all keys, including SQL NULL values; dropping one would shift positional bindings.
    public init(
        entity: VocabularyPersistenceEntity, id: String, parentID: String?, position: Int,
        payload: Data, indexValues: [VocabularyPersistenceIndex: String?] = [:]
    ) throws {
        guard position >= 0, Set(indexValues.keys) == Set(entity.indexKeys) else {
            throw VocabularyError.invalidArchive
        }
        let value: VocabularyDatabaseRecord.Payload
        do { value = try .decode(payload, table: entity) } catch { throw VocabularyError.invalidArchive }
        record = .init(table: entity, id: id, parentID: parentID, position: position, payload: value,
            extra: entity.indexKeys.map { indexValues[$0] ?? nil })
    }

    init(record: VocabularyDatabaseRecord) throws {
        guard record.extra.count == record.table.indexKeys.count else { throw VocabularyError.invalidArchive }
        self.record = record
    }

    public func indexValue(_ key: VocabularyPersistenceIndex) -> String? {
        guard let index = entity.indexKeys.firstIndex(of: key) else { return nil }
        return record.extra[index]
    }

    public func encodedPayload() throws -> Data { try record.payload.encoded() }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.record == rhs.record }
}

/// A header bit preserves nil versus an explicitly empty template collection, which cannot be
/// reconstructed from rows alone. Revision/workspace identity belong to the store's transaction.
public nonisolated struct VocabularyPersistenceRows: Equatable, Sendable {
    public let rows: [VocabularyPersistenceRow]
    public let reviewTemplatesPresent: Bool

    public init(rows: [VocabularyPersistenceRow], reviewTemplatesPresent: Bool) {
        self.rows = rows
        self.reviewTemplatesPresent = reviewTemplatesPresent
    }

    public func keyedRows() throws -> [VocabularyPersistenceRow.Key: VocabularyPersistenceRow] {
        guard Set(rows.map(\.key)).count == rows.count else { throw VocabularyError.invalidArchive }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
    }
}

/// One lossless mapping serves both the legacy Mac schema and Nibomo's workspace-scoped tables.
/// Hosts own SQL, transactions and files. The codec checks reconstruction against the original
/// rows to reject orphans, position gaps and index/payload disagreement without discarding data.
/// Full document validation/preparation remains the shared domain policy's responsibility.
/// These local rows include optional tool metadata and must not be used as a cloud wire payload.
public nonisolated enum VocabularyPersistenceCodec {
    public static func encode(_ document: VocabularyDocument) throws -> VocabularyPersistenceRows {
        let records = try VocabularyDatabaseProjection.rows(document)
        let rows = try records.values.map(VocabularyPersistenceRow.init(record:)).sorted {
            if $0.entity != $1.entity { return $0.entity.rawValue < $1.entity.rawValue }
            if $0.parentID != $1.parentID { return ($0.parentID ?? "") < ($1.parentID ?? "") }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id < $1.id
        }
        return .init(rows: rows, reviewTemplatesPresent: document.reviewTemplates != nil)
    }

    public static func decode(_ encoded: VocabularyPersistenceRows) throws -> VocabularyDocument {
        try VocabularyDatabaseProjection.document(encoded.rows.map(\.record), hasTemplates: encoded.reviewTemplatesPresent)
    }
}
