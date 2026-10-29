import Foundation

/// A transient path projection belongs to one sidebar render. Paths distinguish a category
/// shown under several parents, while counts and filtering always deduplicate meaning IDs.
nonisolated enum VocabularyClassificationProjection {
    struct Row: Identifiable {
        let id: String
        let category: VocabularyCategory
        let title: String
        let depth: Int
        let hasChildren: Bool
        let meaningCount: Int
    }

    static func rows(_ index: VocabularyClassificationIndex, nodes: [VocabularyMeaningNode],
                     languages: [LearningLanguage], expanded: Set<String>, query: String = "") -> [Row] {
        let hidden = Set(index.overrides.filter(\.isHidden).map(\.categoryID))
        let categories = index.categories.filter { !$0.isRetired && !hidden.contains($0.id) }
        let visible = Set(categories.map(\.id)), nodeIDs = Set(nodes.map(\.id))
        let edges = index.parents.filter { visible.contains($0.categoryID) && visible.contains($0.parentID) }
        let children = Dictionary(grouping: edges, by: \.parentID)
        let parented = Set(edges.map(\.categoryID))
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches = Set(categories.filter { category in
            let value = VocabularyClassificationPolicy.effective(category, in: index)
            return terms.allSatisfy { term in
                value.labels.contains { $0.text.localizedStandardContains(term) } || value.definition.localizedStandardContains(term)
            }
        }.map(\.id))
        if !terms.isEmpty {
            var queue = Array(matches), cursor = 0
            let parents = Dictionary(grouping: edges, by: \.categoryID)
            while cursor < queue.count {
                let id = queue[cursor]; cursor += 1
                for edge in parents[id, default: []] where matches.insert(edge.parentID).inserted { queue.append(edge.parentID) }
            }
        }
        var result: [Row] = []
        // Explicit stack bounds traversal and avoids recursive View types. Validated input is
        // acyclic; the path guard and row budget also protect an in-progress detached draft.
        var stack = categories.filter { !parented.contains($0.id) }.reversed().map { ($0.id, "", 0, Set<UUID>()) }
        while let (id, parentPath, depth, ancestors) = stack.popLast(), result.count < 10_000 {
            guard let category = byID[id], !ancestors.contains(id), terms.isEmpty || matches.contains(id) else { continue }
            let path = parentPath + "/" + id.uuidString
            let childIDs = children[id, default: []].map(\.categoryID)
            result.append(.init(id: path, category: category,
                title: VocabularyClassificationPolicy.title(category, in: index, languages: languages), depth: depth,
                hasChildren: !childIDs.isEmpty,
                meaningCount: VocabularyClassificationPolicy.meaningIDs(in: id, index: index).intersection(nodeIDs).count))
            if expanded.contains(path) || !terms.isEmpty {
                var seen = ancestors; seen.insert(id)
                for child in childIDs.reversed() { stack.append((child, path, depth + 1, seen)) }
            }
        }
        return result
    }
}
