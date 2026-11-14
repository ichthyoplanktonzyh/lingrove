import Foundation
import LingroveNotebook

/// Resolves an ordered set against the archive's one captured document, without IO or writes.
/// Keeping selection and cumulative budgeting here prevents a CLI/MCP batch from becoming a
/// loop of separate reads with mismatched revisions, or silently returning only the found IDs.
nonisolated enum VocabularyCLIBatchRead {
    static func read(_ selection: CLIReadSelection, from document: VocabularyDocument,
                     joinedEntries: [VocabularyEntry]? = nil) throws -> [String: CLIJSON] {
        try selection.validate()
        let entries = joinedEntries ?? document.entries
        let selected: [VocabularyEntry]
        switch selection.kind {
        case .entries:
            let index = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            selected = try selection.ids.map { id in
                guard let entry = index[id] else { throw missing("Entry", id) }
                return entry
            }
        case .senses:
            let owners = Dictionary(uniqueKeysWithValues: entries.flatMap { entry in entry.senses.map { ($0.id, entry) } })
            selected = try selection.ids.map { id in
                guard var entry = owners[id] else { throw missing("Sense", id) }
                entry.senses.removeAll { $0.id != id }
                return entry
            }
        }
        try VocabularyCLIReadBudget.validate(selected)
        let projection = NotebookSenseProjection(document, selecting: Set(selected.flatMap(\.senses).map(\.id)))
        let values = switch selection.kind {
        case .entries: try selected.map { try projection.entry($0) }
        case .senses: try zip(selection.ids, selected).map { id, entry in try projection.sense(id, in: entry) }
        }
        var result = [selection.kind.rawValue: CLIJSON.array(values)]
        if selection.includeClassification == true {
            let senses = Set(selected.lazy.flatMap(\.senses).map(\.id))
            result["categoryMemberships"] = .array(memberships(in: document, senses: senses))
        }
        return result
    }

    private static func memberships(in document: VocabularyDocument, senses: Set<UUID>) -> [CLIJSON] {
        let nodes = Set(document.semantics.mappings.lazy.filter { senses.contains($0.senseID) }.map(\.nodeID))
        let keys = Dictionary(uniqueKeysWithValues: document.classification.categories.compactMap { category in
            category.key.map { (category.id, $0) }
        })
        return document.classification.memberships.compactMap { membership -> CLIJSON? in
            guard nodes.contains(membership.nodeID) else { return nil }
            return .object(["id": .string(membership.id.uuidString), "nodeID": .string(membership.nodeID.uuidString),
                "categoryID": .string(membership.categoryID.uuidString),
                "key": keys[membership.categoryID].map(CLIJSON.string) ?? .null])
        }
    }

    private static func missing(_ kind: String, _ id: UUID) -> CLIError {
        .init(code: .notFound, message: kind + " not found: " + id.uuidString + ". No partial batch was returned.")
    }
}
