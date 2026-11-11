import Foundation

/// The lossless row module reduces actual payload changes to their lexical/evidence owners.
/// Stores combine the before/after roots with validated document values; position compaction
/// alone is not a material edit. It carries no SQL connection and grants no write authority.
public nonisolated struct VocabularyPersistenceMaterialRoots: Sendable {
    public var entryIDs: Set<UUID> = []
    public var senseIDs: Set<UUID> = []
    public var sourceIDs: Set<UUID> = []
    public var occurrenceIDs: Set<UUID> = []
    public var allReviewMaterial = false
    public init() {}
}
