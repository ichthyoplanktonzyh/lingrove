import Foundation

/// A transient path projection belongs to one sidebar or picker render. Paths distinguish a
/// category shown under several parents, while counts and filtering always deduplicate meaning IDs.
nonisolated enum VocabularyClassificationProjection {
    struct Row: Identifiable {
        let id: String
        let category: VocabularyCategory
        let title: String
        let depth: Int
        let hasChildren: Bool
        let meaningCount: Int
        var breadcrumb: [String] = []
        var symbolName: String = "folder"
        var isHidden = false
    }

    static func rows(
        _ index: VocabularyClassificationIndex,
        nodes: [VocabularyMeaningNode],
        languages: [LearningLanguage],
        expanded: Set<String>,
        query: String = "",
        includeHidden: Bool = false,
        excludedIDs: Set<UUID> = []
    ) -> [Row] {
        let hidden = Set(index.overrides.filter(\.isHidden).map(\.categoryID))
        let categories = index.categories.filter { category in
            !category.isRetired && !excludedIDs.contains(category.id) &&
                (includeHidden || !hidden.contains(category.id))
        }
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
        var stack = categories.filter { !parented.contains($0.id) }.reversed().map {
            ($0.id, "", 0, Set<UUID>(), [String](), rootSymbol(for: $0))
        }
        while let (id, parentPath, depth, ancestors, trail, inheritedSymbol) = stack.popLast(), result.count < 10_000 {
            guard let category = byID[id], !ancestors.contains(id), terms.isEmpty || matches.contains(id) else { continue }
            let path = parentPath + "/" + id.uuidString
            let childIDs = children[id, default: []].map(\.categoryID)
            let itemTitle = VocabularyClassificationPolicy.title(category, in: index, languages: languages)
            let nextTrail = trail + [itemTitle]
            let icon = depth == 0 ? rootSymbol(for: category) : inheritedSymbol
            result.append(.init(
                id: path,
                category: category,
                title: itemTitle,
                depth: depth,
                hasChildren: !childIDs.isEmpty,
                meaningCount: VocabularyClassificationPolicy.meaningIDs(in: id, index: index).intersection(nodeIDs).count,
                breadcrumb: nextTrail,
                symbolName: icon,
                isHidden: hidden.contains(id)
            ))
            if expanded.contains(path) || !terms.isEmpty {
                var seen = ancestors; seen.insert(id)
                for child in childIDs.reversed() {
                    stack.append((child, path, depth + 1, seen, nextTrail, icon))
                }
            }
        }
        return result
    }

    /// Resolves the primary ancestor title chain from root down to `categoryID` so chips and
    /// breadcrumbs can render contextual paths such as "Time and progression › Timing".
    static func breadcrumb(
        for categoryID: UUID,
        in index: VocabularyClassificationIndex,
        languages: [LearningLanguage]
    ) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: index.categories.map { ($0.id, $0) })
        guard let target = byID[categoryID] else { return [] }
        let hidden = Set(index.overrides.filter(\.isHidden).map(\.categoryID))
        let parents = Dictionary(grouping: index.parents, by: \.categoryID)
        var chain: [VocabularyCategory] = [target]
        var seen: Set<UUID> = [categoryID]
        while let current = chain.last {
            let candidates = parents[current.id, default: []].compactMap { byID[$0.parentID] }.filter { !$0.isRetired }
            guard let chosen = candidates.first(where: { !hidden.contains($0.id) }) ?? candidates.first,
                  seen.insert(chosen.id).inserted else { break }
            chain.append(chosen)
        }
        return chain.reversed().map {
            VocabularyClassificationPolicy.title($0, in: index, languages: languages)
        }.filter { !$0.isEmpty }
    }

    /// Computes the set of tree disclosure path keys (`/rootUUID/childUUID`) that must be
    /// inserted into `expanded` to reveal all `targetIDs` along their primary parent chain.
    static func expansionPaths(
        for targetIDs: Set<UUID>,
        in index: VocabularyClassificationIndex,
        includeHidden: Bool = false
    ) -> Set<String> {
        let hidden = Set(index.overrides.filter(\.isHidden).map(\.categoryID))
        let visible = Set(index.categories.filter {
            !$0.isRetired && (includeHidden || !hidden.contains($0.id))
        }.map(\.id))
        let parents = Dictionary(grouping: index.parents.filter { visible.contains($0.parentID) }, by: \.categoryID)
        var paths: Set<String> = []
        for id in targetIDs where visible.contains(id) {
            var chain = [id], seen: Set<UUID> = [id]
            while let current = chain.last,
                  let parent = parents[current]?.first?.parentID,
                  seen.insert(parent).inserted {
                chain.append(parent)
            }
            var key = ""
            for ancestor in chain.reversed().dropLast() {
                key += "/" + ancestor.uuidString
                paths.insert(key)
            }
        }
        return paths
    }

    /// Returns a semantic SF Symbol for a category by inspecting its catalog key prefix or axis.
    static func symbolName(for category: VocabularyCategory, in index: VocabularyClassificationIndex) -> String {
        if let key = category.key {
            return symbolForCatalogKey(key, axis: category.axis)
        }
        let byID = Dictionary(uniqueKeysWithValues: index.categories.map { ($0.id, $0) })
        let parents = Dictionary(grouping: index.parents, by: \.categoryID)
        var cursor: VocabularyCategory? = category
        var seen: Set<UUID> = [category.id]
        while let current = cursor {
            if let key = current.key {
                return symbolForCatalogKey(key, axis: current.axis)
            }
            guard let parentID = parents[current.id]?.first?.parentID,
                  seen.insert(parentID).inserted,
                  let next = byID[parentID] else { break }
            cursor = next
        }
        return rootSymbol(for: category)
    }

    private static func rootSymbol(for category: VocabularyCategory) -> String {
        if let key = category.key {
            return symbolForCatalogKey(key, axis: category.axis)
        }
        return category.axis == .content ? "folder" : "bubble.left.and.bubble.right"
    }

    private static let catalogSymbols: [String: String] = [
        "content.general": "sparkles",
        "content.quantity": "number",
        "content.degree": "dial.medium",
        "content.time": "clock",
        "content.space": "mappin.and.ellipse",
        "content.motion": "figure.walk",
        "content.perception": "eye",
        "content.body": "heart.text.square",
        "content.emotion": "face.smiling",
        "content.cognition": "brain.head.profile",
        "content.agency": "target",
        "content.interaction": "person.2",
        "content.society": "building.columns",
        "content.work": "briefcase",
        "content.economy": "banknote",
        "content.objects": "cube",
        "content.nature": "leaf",
        "content.food": "cup.and.saucer",
        "content.communication": "text.bubble",
        "content.arts": "paintpalette",
        "function.information": "arrow.left.arrow.right.circle",
        "function.attitude": "heart.circle",
        "function.influence": "hand.point.right",
        "function.social": "hand.wave",
        "function.discourse": "text.alignleft",
        "function.repair": "arrow.triangle.2.circlepath"
    ]

    private static func symbolForCatalogKey(_ key: String, axis: VocabularyCategory.Axis) -> String {
        let prefix = key.split(separator: ".").prefix(2).joined(separator: ".")
        return catalogSymbols[prefix] ?? (axis == .content ? "folder" : "bubble.left.and.bubble.right")
    }
}
