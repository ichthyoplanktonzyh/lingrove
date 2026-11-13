import Foundation
import LingroveNotebook

/// One synchronous SQL read owns this decoder. Reusing Foundation's decoder and the entity's
/// ordered index columns avoids rebuilding a dictionary and two key sets for every row.
/// It has no connection, transaction or validation authority; the lossless codec/domain checks
/// still establish the complete proof. Keep it local to one serialized reader, not UI state.
public nonisolated final class VocabularyPersistenceRowDecoder {
    private let decoder = JSONDecoder()

    public init() {}

    /// Index values follow key.entity.indexKeys exactly, including SQL NULL slots. Reject a
    /// missing/extra slot before decoding; the later row-shape check verifies each value itself.
    public func decode(_ key: VocabularyPersistenceRow.Key, parentID: String?, position: Int,
                       payload: Data, orderedIndexes: [String?]) throws -> VocabularyPersistenceRow {
        guard position >= 0, orderedIndexes.count == key.entity.indexKeys.count else { throw VocabularyError.invalidArchive }
        let value: VocabularyDatabaseRecord.Payload
        do {
            value = try .decode(payload, table: key.entity, decoder: decoder)
        } catch { throw VocabularyError.invalidArchive }
        return try .init(record: .init(table: key.entity, id: key.id, parentID: parentID,
            position: position, payload: value, extra: orderedIndexes))
    }
}
