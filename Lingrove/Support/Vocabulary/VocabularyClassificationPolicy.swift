import Foundation

/// Both CLI plans and UI drafts cross these pure rules before archive persistence. The policy
/// owns graph integrity, draft reconciliation and unique descendant aggregation, never file IO.
nonisolated enum VocabularyClassificationPolicy {
    static func validate(_ index: VocabularyClassificationIndex, nodes: [VocabularyMeaningNode]) throws {
        guard index.frameworks.count <= 64, index.categories.count <= 20_000, index.parents.count <= 100_000,
              index.memberships.count <= 500_000, index.overrides.count <= 20_000 else { throw VocabularyError.invalidContent }
        let categories = try identified(index.categories), frameworks = try identified(index.frameworks)
        _ = try identified(index.parents); _ = try identified(index.memberships); _ = try identified(index.overrides)
        try validateDefinitions(index, frameworks: frameworks)
        try validateParents(index, categories: categories)
        try validateMemberships(index, categories: categories, nodeIDs: Set(nodes.map(\.id)))
    }

    private static func validateDefinitions(
        _ index: VocabularyClassificationIndex, frameworks: [UUID: VocabularyClassificationFramework]
    ) throws {
        var keys = Set<String>()
        for framework in index.frameworks {
            guard !framework.key.isEmpty, framework.key.utf8.count <= 200, framework.version > 0,
                  keys.insert(framework.key).inserted else { throw VocabularyError.invalidContent }
        }
        keys = []
        for category in index.categories {
            try validateLabels(category.labels)
            try text(category.definition)
            try provenance(category.provenance)
            if let frameworkID = category.frameworkID {
                guard frameworks[frameworkID] != nil, let key = category.key, !key.isEmpty, key.utf8.count <= 200,
                      keys.insert(frameworkID.uuidString + key).inserted else { throw VocabularyError.invalidContent }
            } else if category.key != nil || category.isRetired { throw VocabularyError.invalidContent }
        }
    }

    private static func validateParents(_ index: VocabularyClassificationIndex, categories: [UUID: VocabularyCategory]) throws {
        var edges = Set<String>(), children: [UUID: [UUID]] = [:], indegree: [UUID: Int] = [:]
        for edge in index.parents {
            guard let child = categories[edge.categoryID], let parent = categories[edge.parentID],
                  child.axis == parent.axis, child.id != parent.id,
                  child.frameworkID == nil || child.frameworkID == parent.frameworkID,
                  edges.insert(edge.categoryID.uuidString + edge.parentID.uuidString).inserted else {
                throw VocabularyError.invalidContent
            }
            children[edge.parentID, default: []].append(edge.categoryID)
            indegree[edge.categoryID, default: 0] += 1
        }
        // Kahn's traversal avoids recursive stack growth on imported or agent-authored hierarchies.
        var queue = index.categories.filter { indegree[$0.id, default: 0] == 0 }.map(\.id), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for child in children[id, default: []] {
                indegree[child, default: 0] -= 1
                if indegree[child] == 0 { queue.append(child) }
            }
        }
        guard queue.count == categories.count else { throw VocabularyError.invalidContent }
    }

    private static func validateMemberships(_ index: VocabularyClassificationIndex, categories: [UUID: VocabularyCategory],
                                            nodeIDs: Set<UUID>) throws {
        var memberships = Set<String>()
        for membership in index.memberships {
            guard nodeIDs.contains(membership.nodeID), categories[membership.categoryID] != nil,
                  memberships.insert(membership.nodeID.uuidString + membership.categoryID.uuidString).inserted else {
                throw VocabularyError.invalidContent
            }
            try provenance(membership.provenance)
        }
        for overlay in index.overrides {
            guard categories[overlay.categoryID] != nil else { throw VocabularyError.invalidContent }
            if let labels = overlay.labels { try validateLabels(labels) }
            if let definition = overlay.definition { try text(definition) }
        }
    }

    static func effective(_ category: VocabularyCategory, in index: VocabularyClassificationIndex) -> VocabularyCategory {
        var value = category
        if let overlay = index.overrides.first(where: { $0.categoryID == category.id }) {
            if let labels = overlay.labels { value.labels = labels }
            if let definition = overlay.definition { value.definition = definition }
        }
        return value
    }

    static func title(_ category: VocabularyCategory, in index: VocabularyClassificationIndex,
                      languages: [LearningLanguage]) -> String {
        VocabularyMeaningLabelPolicy.label(in: effective(category, in: index).labels, languages: languages)?.text ?? ""
    }

    static func descendants(of id: UUID, in index: VocabularyClassificationIndex) -> Set<UUID> {
        let children = Dictionary(grouping: index.parents, by: \.parentID)
        var found: Set<UUID> = [id], queue = [id], cursor = 0
        while cursor < queue.count {
            let next = queue[cursor]; cursor += 1
            for edge in children[next, default: []] where found.insert(edge.categoryID).inserted { queue.append(edge.categoryID) }
        }
        return found
    }

    static func meaningIDs(in categoryID: UUID, index: VocabularyClassificationIndex) -> Set<UUID> {
        let categories = descendants(of: categoryID, in: index)
        return Set(index.memberships.filter {
            categories.contains($0.categoryID) && $0.provenance.status == .confirmed
        }.map(\.nodeID))
    }

    /// Selective interchange carries only memberships for exported meanings and their category
    /// ancestors. Unrelated categories and user overlays stay out of a small expression export.
    static func selected(_ index: VocabularyClassificationIndex, nodes: [VocabularyMeaningNode]) -> VocabularyClassificationIndex {
        let nodeIDs = Set(nodes.map(\.id)), parents = Dictionary(grouping: index.parents, by: \.categoryID)
        let memberships = index.memberships.filter { nodeIDs.contains($0.nodeID) }
        var ids = Set(memberships.map(\.categoryID)), queue = Array(ids), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for edge in parents[id, default: []] where ids.insert(edge.parentID).inserted { queue.append(edge.parentID) }
        }
        let categories = index.categories.filter { ids.contains($0.id) }, frameworks = Set(categories.compactMap(\.frameworkID))
        return .init(frameworks: index.frameworks.filter { frameworks.contains($0.id) }, categories: categories,
            parents: index.parents.filter { ids.contains($0.categoryID) && ids.contains($0.parentID) }, memberships: memberships,
            overrides: index.overrides.filter { ids.contains($0.categoryID) })
    }

    /// Removing a custom folder detaches its children and memberships, retaining every meaning.
    static func removeCategory(_ id: UUID, from index: inout VocabularyClassificationIndex) throws {
        guard index.categories.contains(where: { $0.id == id && $0.frameworkID == nil }) else {
            throw VocabularyError.invalidContent
        }
        index.categories.removeAll { $0.id == id }
        index.parents.removeAll { $0.categoryID == id || $0.parentID == id }
        index.memberships.removeAll { $0.categoryID == id }
        index.overrides.removeAll { $0.categoryID == id }
    }

    /// Entity-level compare-and-swap preserves independent CLI changes while a sheet is open.
    static func merge(_ edited: VocabularyClassificationIndex, baseline: VocabularyClassificationIndex,
                      current: VocabularyClassificationIndex) throws -> VocabularyClassificationIndex {
        let builtIns = Set(baseline.categories.filter { $0.frameworkID != nil }.map(\.id))
        guard edited.frameworks == baseline.frameworks,
              edited.categories.filter({ $0.frameworkID != nil }) == baseline.categories.filter({ $0.frameworkID != nil }),
              edited.parents.filter({ builtIns.contains($0.categoryID) }) ==
                baseline.parents.filter({ builtIns.contains($0.categoryID) }) else {
            throw VocabularyError.invalidContent
        }
        var result = current
        result.categories = try mergeRows(edited.categories, baseline: baseline.categories, current: current.categories)
        result.parents = try mergeRows(edited.parents, baseline: baseline.parents, current: current.parents)
        result.memberships = try mergeRows(edited.memberships, baseline: baseline.memberships,
            current: current.memberships)
        result.overrides = try mergeRows(edited.overrides, baseline: baseline.overrides, current: current.overrides)
        return result
    }

    private static func mergeRows<T: Identifiable & Equatable>(_ edited: [T], baseline: [T], current: [T]) throws -> [T]
        where T.ID == UUID {
        var result = current
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            guard current.first(where: { $0.id == before.id }) == before else { throw VocabularyError.editConflict }
            result.removeAll { $0.id == before.id }
        }
        for after in edited where baseline.first(where: { $0.id == after.id }) != after {
            let before = baseline.first { $0.id == after.id }, live = current.first { $0.id == after.id }
            guard live == before || live == after else { throw VocabularyError.editConflict }
            if let position = result.firstIndex(where: { $0.id == after.id }) { result[position] = after } else { result.append(after) }
        }
        return result
    }

    private static func identified<T: Identifiable>(_ values: [T]) throws -> [UUID: T] where T.ID == UUID {
        guard Set(values.map(\.id)).count == values.count else { throw VocabularyError.invalidContent }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }
    private static func text(_ value: String) throws {
        guard value.utf8.count <= 16_384 else { throw VocabularyError.invalidContent }
    }
    private static func validateLabels(_ labels: [VocabularyMeaningLabel]) throws {
        guard !labels.isEmpty, labels.count <= 64, Set(labels.map(\.id)).count == labels.count else { throw VocabularyError.invalidContent }
        var preferred = Set<String>()
        for label in labels {
            guard !label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  label.text.utf8.count <= 4_096 else { throw VocabularyError.invalidContent }
            if label.preferred, !preferred.insert(label.language?.rawValue ?? "und").inserted { throw VocabularyError.invalidContent }
        }
        guard !preferred.isEmpty else { throw VocabularyError.invalidContent }
    }
    private static func provenance(_ value: VocabularySemanticProvenance) throws {
        try text(value.source)
        if let score = value.confidence, !score.isFinite || !(0...1).contains(score) { throw VocabularyError.invalidContent }
    }
}
