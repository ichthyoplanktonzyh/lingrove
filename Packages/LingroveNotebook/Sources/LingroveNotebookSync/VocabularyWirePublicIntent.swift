import CryptoKit
import Foundation
import LingroveNotebook

/// Classifies a local save using the public wire projection, not persistence
/// rows. Private tool receipts and timestamp-only bookkeeping must not undo a
/// user's cancellation. This local comparison is not a server canonical hash.
public nonisolated enum VocabularyWirePublicIntent {
    public static func hasChanges(from previous: VocabularyDocument, to next: VocabularyDocument, notebookID: UUID) throws -> Bool {
        try digest(previous, notebookID: notebookID) != digest(next, notebookID: notebookID)
    }
    private static func digest(_ document: VocabularyDocument, notebookID: UUID) throws -> Data {
        let entities = try VocabularyWireProjectionCodec.project(document, notebookID: notebookID).entities
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256(); hash.update(data: Data("lingrove-local-public-intent:1\n".utf8))
        for entity in entities.sorted(by: { ($0.entityType.rawValue + ":" + $0.entityID) < ($1.entityType.rawValue + ":" + $1.entityID) }) {
            var fields = entity.fields; fields.removeValue(forKey: "updatedAt")
            let bytes = try encoder.encode(VocabularyWireJSON.object(["type": .string(entity.entityType.rawValue), "id": .string(entity.entityID), "fields": .object(fields)]))
            hash.update(data: Data("\(bytes.count)\n".utf8)); hash.update(data: bytes); hash.update(data: Data("\n".utf8))
        }
        return Data(hash.finalize())
    }
}
