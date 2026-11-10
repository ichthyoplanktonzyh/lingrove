import Foundation

/// Dry runs and commit receipts describe the same detached before/after values. The caller
/// limits encoded size before committing. Previewing never writes, classifies or asks a model.
public nonisolated enum NotebookChangePreview {
    public static func make(before: VocabularyDocument, after: VocabularyDocument) throws -> NotebookToolJSON {
        let oldSenses = try NotebookSenseProjection(before).senses()
        let newSenses = try NotebookSenseProjection(after).senses()
        var resources: [NotebookToolJSON] = []
        for name in NotebookResourceContract.names where name != "entries" && name != "senses" && changed(name, before, after) {
            let old = try records(name, before), new = try records(name, after)
            resources += differences(old, new).map { value in
                guard case var .object(fields) = value else { return value }
                fields["resource"] = .string(name); return .object(fields)
            }
        }
        return .object(["senses": .array(differences(oldSenses, newSenses)),
            "entries": .array(differences(try records("entries", before), try records("entries", after))),
            "resources": .array(resources)])
    }

    private static func records(_ name: String, _ document: VocabularyDocument) throws -> [UUID: NotebookToolJSON] {
        try Dictionary(uniqueKeysWithValues: NotebookResources.records(name, in: document).map { record in
            var value = record
            if case var .object(fields) = value {
                fields.removeValue(forKey: "createdAt"); fields.removeValue(forKey: "updatedAt")
                value = .object(fields)
            }
            return (try NotebookResources.identifier(record, resource: name), value)
        })
    }

    private static func differences(_ before: [UUID: NotebookToolJSON], _ after: [UUID: NotebookToolJSON]) -> [NotebookToolJSON] {
        Set(before.keys).union(after.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard before[id] != after[id] else { return nil }
            return .object(["id": .string(id.uuidString),
                "action": .string(before[id] == nil ? "created" : after[id] == nil ? "removed" : "updated"),
                "before": before[id] ?? .null, "after": after[id] ?? .null])
        }
    }

    // Skip unchanged groups before serialization; ordinary text edits do not serialize the
    // entire classification catalog just because the notebook contains many categories.
    private static func changed(_ name: String, _ a: VocabularyDocument, _ b: VocabularyDocument) -> Bool {
        switch name {
        case "sources": a.sources != b.sources
        case "occurrences": a.occurrences != b.occurrences
        case "interpretations": a.interpretations != b.interpretations
        case "nodes": a.semantics.nodes != b.semantics.nodes
        case "patterns": a.semantics.patterns != b.semantics.patterns
        case "mappings": a.semantics.mappings != b.semantics.mappings
        case "relations": a.semantics.relations != b.semantics.relations
        case "cues": a.semantics.cues != b.semantics.cues
        case "cueTargets": a.semantics.cueTargets != b.semantics.cueTargets
        case "frameworks": a.classification.frameworks != b.classification.frameworks
        case "categories": a.classification.categories != b.classification.categories
        case "categoryParents": a.classification.parents != b.classification.parents
        case "categoryMemberships": a.classification.memberships != b.classification.memberships
        case "categoryOverrides": a.classification.overrides != b.classification.overrides
        default: false
        }
    }
}
