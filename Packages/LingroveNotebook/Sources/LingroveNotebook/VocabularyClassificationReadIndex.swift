import Foundation

/// A caller-owned projection for repeated taxonomy reads. Group relationships once per saved
/// classification, then visit only the requested subtree. It owns no archive or write authority;
/// graph builders and detail caches discard it when their saved classification changes.
public nonisolated struct VocabularyClassificationReadIndex: Sendable {
    private let children: [UUID: [UUID]]
    private let meanings: [UUID: Set<UUID>]

    public init(_ index: VocabularyClassificationIndex) {
        children = Dictionary(grouping: index.parents, by: \.parentID).mapValues { $0.map(\.categoryID) }
        meanings = Dictionary(grouping: index.memberships.filter { $0.provenance.status == .confirmed }, by: \.categoryID)
            .mapValues { Set($0.map(\.nodeID)) }
    }

    public func descendants(of id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id], queue = [id], cursor = 0
        while cursor < queue.count {
            let next = queue[cursor]; cursor += 1
            for child in children[next, default: []] where found.insert(child).inserted { queue.append(child) }
        }
        return found
    }

    /// Sets retain unique membership across multiple DAG paths. Transitive sets are computed
    /// on demand, avoiding a retained category × meaning matrix for deep imported hierarchies.
    public func meaningIDs(in categoryID: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        for id in descendants(of: categoryID) { result.formUnion(meanings[id, default: []]) }
        return result
    }
}
