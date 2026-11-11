import Foundation

/// The domain writer seals this scope after applying record expectations to its own checked
/// state. Codec and sync adapters may select these roots, but cannot manufacture a dirty-ID
/// hint that bypasses validation. The value lives only from preparation through one commit.
public nonisolated struct VocabularyOrganizationSaveChange: Sendable {
    public let previous: VocabularyDocument
    public let state: VocabularyEntrySaveState
    public let scope: VocabularyOrganizationScope
    init(previous: VocabularyDocument, state: VocabularyEntrySaveState, scope: VocabularyOrganizationScope) {
        self.previous = previous; self.state = state; self.scope = scope
    }
}

/// Independently identified organization roots own their labels, roles, slots and bindings.
/// This derived scope crosses module boundaries; only the domain command can construct it.
public nonisolated struct VocabularyOrganizationScope: Sendable {
    public let nodes, patterns, mappings, relations, cues, targets: Set<UUID>
    public let categories, parents, memberships, overrides: Set<UUID>

    init(_ edit: VocabularyOrganizationEdit, before: VocabularyDocument, after: VocabularyDocument) {
        nodes = edit.semantic?.nodes.changedIDs ?? []; patterns = edit.semantic?.patterns.changedIDs ?? []
        mappings = edit.semantic?.mappings.changedIDs ?? []; relations = edit.semantic?.relations.changedIDs ?? []
        cues = edit.semantic?.cues.changedIDs ?? []; targets = edit.semantic?.targets.changedIDs ?? []
        categories = edit.classification?.categories.changedIDs ?? []; parents = edit.classification?.parents.changedIDs ?? []
        overrides = edit.classification?.overrides.changedIDs ?? []
        // Node removal also retires its directory memberships inside the same domain command.
        let retired = Set(before.classification.memberships.map(\.id)).subtracting(after.classification.memberships.map(\.id))
        memberships = (edit.classification?.memberships.changedIDs ?? []).union(retired)
    }

    public func semantics(in index: VocabularySemanticIndex) -> VocabularySemanticIndex {
        .init(nodes: index.nodes.filter { nodes.contains($0.id) },
            patterns: index.patterns.filter { patterns.contains($0.id) },
            mappings: index.mappings.filter { mappings.contains($0.id) },
            relations: index.relations.filter { relations.contains($0.id) },
            cues: index.cues.filter { cues.contains($0.id) },
            cueTargets: index.cueTargets.filter { targets.contains($0.id) })
    }

    public func classification(in index: VocabularyClassificationIndex) -> VocabularyClassificationIndex {
        .init(frameworks: [], categories: index.categories.filter { categories.contains($0.id) },
            parents: index.parents.filter { parents.contains($0.id) },
            memberships: index.memberships.filter { memberships.contains($0.id) },
            overrides: index.overrides.filter { overrides.contains($0.id) })
    }

    public func fragment(in document: VocabularyDocument) -> VocabularyDocument {
        .init(semantics: semantics(in: document.semantics), classification: classification(in: document.classification))
    }
}
