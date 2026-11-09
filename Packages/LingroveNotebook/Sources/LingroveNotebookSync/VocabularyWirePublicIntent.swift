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
    /// A validated entry command leaves directory/templates and unrelated corpus roots intact.
    /// Structural changes are public immediately; otherwise compare only the affected fragments
    /// through the same public leaf encoder. Private bindings/audio and updatedAt stay excluded,
    /// preserving cancellation/frozen-ACK semantics without hashing the whole notebook twice.
    public static func hasChanges(_ change: VocabularyEntrySaveChange, notebookID: UUID) throws -> Bool {
        let before = change.previous, after = change.document
        if before.catalog.map(\.id) != after.catalog.map(\.id) || before.sources.map(\.id) != after.sources.map(\.id) ||
            before.occurrences.map(\.id) != after.occurrences.map(\.id) ||
            before.interpretations.map(\.id) != after.interpretations.map(\.id) { return true }
        let senses = change.affectedSenseIDs
        let claims = Set((before.interpretations + after.interpretations).filter {
            $0.senseID.map(senses.contains) == true
        }.map(\.id))
        func fragment(_ document: VocabularyDocument) -> VocabularyDocument {
            .init(catalog: document.catalog.filter { $0.id == change.entryID }, sources: [], occurrences: [],
                interpretations: document.interpretations.filter { claims.contains($0.id) },
                semantics: before.semantics == after.semantics ? .init() : document.semantics)
        }
        var oldEncoder = VocabularyWireEncoder(), newEncoder = VocabularyWireEncoder()
        return try digest(oldEncoder.encode(fragment(before), notebookID: notebookID)) !=
            digest(newEncoder.encode(fragment(after), notebookID: notebookID))
    }

    private static func digest(_ document: VocabularyDocument, notebookID: UUID) throws -> Data {
        let entities = try VocabularyWireProjectionCodec.project(document, notebookID: notebookID).entities
        return try digest(entities)
    }
    private static func digest(_ entities: [VocabularyWireEntity]) throws -> Data {
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
