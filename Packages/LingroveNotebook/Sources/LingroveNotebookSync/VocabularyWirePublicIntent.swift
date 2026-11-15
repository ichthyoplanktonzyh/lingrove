import CryptoKit
import Foundation
import LingroveNotebook

/// Classifies a local save using the public wire projection, not persistence
/// rows. Private tool receipts and timestamp-only bookkeeping must not undo a
/// user's cancellation. This local comparison is not a server canonical hash.
public nonisolated enum VocabularyWirePublicIntent {
    /// The sealed command changes only public sense-tag membership and bookkeeping dates.
    /// A nonempty removal is public by construction; no corpus fragment needs serialization.
    public static func hasChanges(_ change: VocabularyTagRemovalChange) -> Bool { !change.removedBySense.isEmpty }

    /// The writer has already validated both complete states. These domain-shaped fragments
    /// contain the roots selected by its actual row delta; they deliberately omit unchanged
    /// owners and may reference records outside the fragment. This is a pure comparison, not
    /// an admission or remote payload, and never performs another whole-document validation.
    public static func hasChangesInValidatedFragments(from previous: VocabularyDocument, to next: VocabularyDocument,
                                                      notebookID: UUID) throws -> Bool {
        var oldEncoder = VocabularyWireEncoder(), newEncoder = VocabularyWireEncoder()
        return try digest(oldEncoder.encode(previous, notebookID: notebookID)) != digest(newEncoder.encode(next, notebookID: notebookID))
    }
    public static func hasChanges(from previous: VocabularyDocument, to next: VocabularyDocument, notebookID: UUID) throws -> Bool {
        try digest(previous, notebookID: notebookID) != digest(next, notebookID: notebookID)
    }
    /// A validated entry command leaves directory/templates and unrelated corpus roots intact.
    /// Structural changes are public immediately; otherwise compare only the affected fragments
    /// through the same public leaf encoder. Private bindings/audio and updatedAt stay excluded,
    /// preserving cancellation/frozen-ACK semantics without hashing the whole notebook twice.
    public static func hasChanges(_ change: VocabularyEntrySaveChange, notebookID: UUID) throws -> Bool {
        let before = change.previous, after = change.document
        // This domain-owned proof contains only public pattern/mapping retirement or actual
        // evidence retraction. Comparing two complete graph encodings adds no information.
        if !change.semanticChange.isEmpty { return true }
        if before.catalog.count != after.catalog.count || before.sources.count != after.sources.count ||
            before.occurrences.count != after.occurrences.count || before.interpretations.count != after.interpretations.count { return true }
        func fragment(_ document: VocabularyDocument, claims: [VocabularyInterpretation]) -> VocabularyDocument {
            .init(catalog: document.catalog.filter { $0.id == change.entryID }, sources: [], occurrences: [],
                interpretations: claims,
                semantics: .init())
        }
        var oldEncoder = VocabularyWireEncoder(), newEncoder = VocabularyWireEncoder()
        return try digest(oldEncoder.encode(fragment(before, claims: change.previousClaims), notebookID: notebookID)) !=
            digest(newEncoder.encode(fragment(after, claims: change.claims), notebookID: notebookID))
    }

    /// Organization edits leave corpus and evidence intact. Encode only changed graph records
    /// through the existing public leaf encoder, preserving private/timestamp exclusions.
    public static func hasOrganizationChanges(from previous: VocabularyDocument, to next: VocabularyDocument,
                                               notebookID: UUID) throws -> Bool {
        let nodes = try changed(previous.semantics.nodes, next.semantics.nodes)
        let patterns = try changed(previous.semantics.patterns, next.semantics.patterns)
        let mappings = try changed(previous.semantics.mappings, next.semantics.mappings)
        let relations = try changed(previous.semantics.relations, next.semantics.relations)
        let cues = try changed(previous.semantics.cues, next.semantics.cues)
        let targets = try changed(previous.semantics.cueTargets, next.semantics.cueTargets)
        let frameworks = try changed(previous.classification.frameworks, next.classification.frameworks)
        let categories = try changed(previous.classification.categories, next.classification.categories)
        let parents = try changed(previous.classification.parents, next.classification.parents)
        let memberships = try changed(previous.classification.memberships, next.classification.memberships)
        let overrides = try changed(previous.classification.overrides, next.classification.overrides)
        let old = VocabularyDocument(catalog: [], sources: [], occurrences: [], interpretations: [],
            semantics: .init(nodes: nodes.0, patterns: patterns.0, mappings: mappings.0, relations: relations.0,
                cues: cues.0, cueTargets: targets.0),
            classification: .init(frameworks: frameworks.0, categories: categories.0, parents: parents.0,
                memberships: memberships.0, overrides: overrides.0))
        let new = VocabularyDocument(catalog: [], sources: [], occurrences: [], interpretations: [],
            semantics: .init(nodes: nodes.1, patterns: patterns.1, mappings: mappings.1, relations: relations.1,
                cues: cues.1, cueTargets: targets.1),
            classification: .init(frameworks: frameworks.1, categories: categories.1, parents: parents.1,
                memberships: memberships.1, overrides: overrides.1))
        var oldEncoder = VocabularyWireEncoder(), newEncoder = VocabularyWireEncoder()
        return try digest(oldEncoder.encode(old, notebookID: notebookID)) != digest(newEncoder.encode(new, notebookID: notebookID))
    }

    private static func changed<T: Identifiable & Equatable>(_ before: [T], _ after: [T]) throws -> ([T], [T]) where T.ID == UUID {
        guard Set(before.map(\.id)).count == before.count,
              Set(after.map(\.id)).count == after.count else { throw VocabularyError.invalidContent }
        guard before != after else { return ([], []) }
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        return (before.filter { new[$0.id] != $0 }, after.filter { old[$0.id] != $0 })
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
