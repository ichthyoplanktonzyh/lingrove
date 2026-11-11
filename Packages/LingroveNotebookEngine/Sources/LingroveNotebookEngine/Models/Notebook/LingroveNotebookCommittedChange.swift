import Foundation
import LingroveNotebook

/// A connection-owned commit receipt describes presentation changes between two exact saved
/// versions. It is derived from checked rows, never accepted as write authority from a caller.
/// Archive/UI can reuse unchanged entry indexes or apply these acknowledged values; a missing
/// receipt or a revision gap always permits a complete read. It is not persisted or synced.
public struct LingroveNotebookCommittedChange: Equatable, Sendable {
    public let base: LingroveNotebookVersion
    public let version: LingroveNotebookVersion
    public let updatedEntries: [VocabularyEntry]
    public let removedEntryIDs: Set<UUID>
    public let requiresEntryReload: Bool
}
