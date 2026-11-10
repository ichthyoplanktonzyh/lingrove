import Foundation
import LingroveNotebook

/// Resolves an ordered set against the archive's one captured document, without IO or writes.
/// Keeping selection and cumulative budgeting here prevents a CLI/MCP batch from becoming a
/// loop of separate reads with mismatched revisions, or silently returning only the found IDs.
nonisolated enum VocabularyCLIBatchRead {
    static func read(_ selection: CLIReadSelection, from document: VocabularyDocument) throws -> [CLIJSON] {
        try selection.validate()
        let entries = document.entries
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
        let projection = NotebookSenseProjection(document)
        switch selection.kind {
        case .entries: return try selected.map { try projection.entry($0) }
        case .senses: return try selection.ids.map { try projection.sense($0) }
        }
    }

    private static func missing(_ kind: String, _ id: UUID) -> CLIError {
        .init(code: .notFound, message: kind + " not found: " + id.uuidString + ". No partial batch was returned.")
    }
}
