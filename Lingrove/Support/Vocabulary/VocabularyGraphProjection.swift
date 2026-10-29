import Foundation

/// Converts the filtered notebook into headword dots and explicitly owned sense branches.
/// Search can reveal a matching sense, but proximity, spelling and model text never create edges.
nonisolated enum VocabularyGraphProjection {
    static func make(entries: [VocabularyEntry], expanded: Set<UUID>, query: String) -> VocabularyGraphSnapshot {
        var graph = VocabularyGraphSnapshot()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        graph.searchQuery = query
        let mixedLanguages = VocabularyMeaningLabelPolicy.hasMultipleLanguages(entries)
        for entry in entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let parent = VocabularyGraphNodeID.headword(entry.id)
            graph.nodes.append(.init(id: parent,
                label: VocabularyMeaningLabelPolicy.expressionTitle(entry, includeLanguage: mixedLanguages)))
            graph.headwordCount += 1
            let headMatches = query.isEmpty || entry.expression.localizedCaseInsensitiveContains(query)
                || entry.dictionaryForm.localizedCaseInsensitiveContains(query)
            if !query.isEmpty && headMatches { graph.matches.insert(parent) }
            guard expanded.contains(entry.id) || !headMatches else { continue }
            for sense in entry.senses {
                let id = VocabularyGraphNodeID.sense(.init(entryID: entry.id, senseID: sense.id))
                graph.nodes.append(.init(id: id, label: sense.displayTitle))
                graph.edges.append(.init(source: parent, target: id))
                if !query.isEmpty && !headMatches {
                    var probe = entry
                    probe.senses = [sense]
                    if VocabularyPolicy.matches(probe, query: query) { graph.matches.insert(id) }
                }
            }
        }
        return graph
    }

    static func meanings(index: VocabularySemanticIndex, entries: [VocabularyEntry], expanded: Set<UUID>, query: String,
                         kind: VocabularyMeaningNode.Kind? = nil, includeEmpty: Bool = true,
                         preferredLanguages: [LearningLanguage] = [],
                         classification: VocabularyClassificationIndex? = nil,
                         showsUnexplored: Bool = false) -> VocabularyGraphSnapshot {
        var graph = VocabularyGraphSnapshot()
        graph.isMeaningGraph = true
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        graph.searchQuery = trimmedQuery

        let items = VocabularyMeaningBrowserProjection.items(
            index: index,
            entries: entries,
            query: trimmedQuery,
            kind: kind,
            includeEmpty: includeEmpty,
            preferredLanguages: preferredLanguages
        )
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let mixedLanguages = VocabularyMeaningLabelPolicy.hasMultipleLanguages(entries)

        let activeClassification = classification ?? VocabularyClassificationIndex()
        let activeCategories = activeClassification.categories.filter { !$0.isRetired }
        if !activeCategories.isEmpty {
            return makeTaxonomyTree(
                index: index,
                classification: activeClassification,
                items: items,
                entries: entries,
                expanded: expanded,
                query: trimmedQuery,
                kind: kind,
                showsUnexplored: showsUnexplored,
                preferredLanguages: preferredLanguages
            )
        }

        // Fallback hierarchical tree when no classification catalog is installed:
        // group meanings directly under their conceptual/functional axes (or root columns).
        let visible = Set(items.map(\.id))
        var included = Set<VocabularyGraphNodeID>()
        for item in items {
            let root = VocabularyGraphNodeID.meaning(item.id)
            let hasSenses = !item.selections.isEmpty
            let isExpanded = expanded.contains(item.id) || !trimmedQuery.isEmpty
            graph.nodes.append(.init(
                id: root,
                label: item.title,
                meaningKind: item.node.kind,
                axis: item.node.kind == .function ? .function : .content,
                depth: 0,
                itemCount: item.selections.count,
                isUnexplored: item.selections.isEmpty,
                hasChildren: hasSenses,
                isExpanded: isExpanded
            ))
            graph.headwordCount += 1
            if !trimmedQuery.isEmpty { graph.matches.insert(root) }
            guard isExpanded else { continue }
            for selection in item.selections {
                guard let entry = entriesByID[selection.entryID],
                      let sense = entry.senses.first(where: { $0.id == selection.senseID })
                else { continue }
                let child = VocabularyGraphNodeID.sense(selection)
                if included.insert(child).inserted {
                    let expression = VocabularyMeaningLabelPolicy.expressionTitle(entry, includeLanguage: mixedLanguages)
                    graph.nodes.append(.init(
                        id: child,
                        label: expression + " · " + sense.displayTitle,
                        axis: item.node.kind == .function ? .function : .content,
                        depth: 1
                    ))
                }
                graph.edges.append(.init(
                    source: root,
                    target: child,
                    kind: item.node.kind == .concept ? .expressesContent : .realizesFunction
                ))
            }
        }
        for relation in VocabularyMeaningBrowserProjection.confirmedRelations(in: index)
            where visible.contains(relation.sourceID) && visible.contains(relation.targetID) {
            graph.edges.append(.init(
                source: .meaning(relation.sourceID),
                target: .meaning(relation.targetID),
                kind: .init(rawValue: relation.kind.rawValue) ?? .related
            ))
        }
        assignTreePositions(in: &graph, columnSpacing: 240, rowSpacing: 52)
        return graph
    }

    private static func makeTaxonomyTree(
        index: VocabularySemanticIndex,
        classification: VocabularyClassificationIndex,
        items: [VocabularyMeaningBrowserProjection.Item],
        entries: [VocabularyEntry],
        expanded: Set<UUID>,
        query: String = "",
        kind: VocabularyMeaningNode.Kind? = nil,
        showsUnexplored: Bool = false,
        preferredLanguages: [LearningLanguage] = []
    ) -> VocabularyGraphSnapshot {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let mixedLanguages = VocabularyMeaningLabelPolicy.hasMultipleLanguages(entries)
        var graph = VocabularyGraphSnapshot()
        graph.isMeaningGraph = true
        graph.searchQuery = query

        let hidden = Set(classification.overrides.filter(\.isHidden).map(\.categoryID))
        let categories = classification.categories.filter { !$0.isRetired && !hidden.contains($0.id) }
        let categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let validCategoryIDs = Set(categories.map(\.id))

        let parentEdges = classification.parents.filter {
            validCategoryIDs.contains($0.categoryID) && validCategoryIDs.contains($0.parentID)
        }
        // Choose one primary parent per category for a clean tree layout, while counts still
        // aggregate across all DAG paths via `VocabularyClassificationPolicy.meaningIDs`.
        let (primaryParent, childCategories) = categoryChildren(edges: parentEdges, categoriesByID: categoriesByID)

        let confirmedMemberships = classification.memberships.filter {
            $0.provenance.status == .confirmed && validCategoryIDs.contains($0.categoryID) && itemsByID[$0.nodeID] != nil
        }
        var directMeaningsByCategory: [UUID: [VocabularyMeaningBrowserProjection.Item]] = [:]
        var categorizedMeaningIDs = Set<UUID>()
        for membership in confirmedMemberships {
            if let item = itemsByID[membership.nodeID] {
                directMeaningsByCategory[membership.categoryID, default: []].append(item)
                categorizedMeaningIDs.insert(item.id)
            }
        }
        for key in directMeaningsByCategory.keys {
            directMeaningsByCategory[key]?.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        let allMatchedMeaningIDs = Set(items.map(\.id))
        let matchingCategoryIDs = matchingCategories(categories, classification: classification, query: query)

        func subtreeMeaningCount(_ categoryID: UUID) -> Int {
            VocabularyClassificationPolicy.meaningIDs(in: categoryID, index: classification)
                .intersection(allMatchedMeaningIDs)
                .count
        }

        func subtreeHasCategoryMatch(_ categoryID: UUID) -> Bool {
            let descendants = VocabularyClassificationPolicy.descendants(of: categoryID, in: classification)
            return !descendants.isDisjoint(with: matchingCategoryIDs)
        }

        var includedNodes = Set<VocabularyGraphNodeID>()
        var visibleMeaningIDs = Set<UUID>()

        func appendNode(_ node: VocabularyGraphNode) {
            guard includedNodes.insert(node.id).inserted else { return }
            graph.nodes.append(node)
        }

        func appendMeanings(
            _ meaningList: [VocabularyMeaningBrowserProjection.Item],
            under parentNodeID: VocabularyGraphNodeID,
            axis: VocabularyCategory.Axis,
            depth: Int
        ) {
            for item in meaningList {
                let meaningNodeID = VocabularyGraphNodeID.meaning(item.id)
                let hasSenses = !item.selections.isEmpty
                let isMeaningExpanded = expanded.contains(item.id) || !query.isEmpty
                visibleMeaningIDs.insert(item.id)
                if includedNodes.insert(meaningNodeID).inserted {
                    graph.nodes.append(.init(
                        id: meaningNodeID,
                        label: item.title,
                        meaningKind: item.node.kind,
                        axis: axis,
                        depth: depth,
                        itemCount: item.selections.count,
                        isUnexplored: item.selections.isEmpty,
                        hasChildren: hasSenses,
                        isExpanded: isMeaningExpanded
                    ))
                    graph.headwordCount += 1
                    if !query.isEmpty {
                        graph.matches.insert(meaningNodeID)
                    }
                }
                graph.edges.append(.init(source: parentNodeID, target: meaningNodeID, kind: .taxonomy))

                guard isMeaningExpanded else { continue }
                for selection in item.selections {
                    guard let entry = entriesByID[selection.entryID],
                          let sense = entry.senses.first(where: { $0.id == selection.senseID })
                    else { continue }
                    let senseNodeID = VocabularyGraphNodeID.sense(selection)
                    if includedNodes.insert(senseNodeID).inserted {
                        let expression = VocabularyMeaningLabelPolicy.expressionTitle(entry, includeLanguage: mixedLanguages)
                        graph.nodes.append(.init(
                            id: senseNodeID,
                            label: expression + " · " + sense.displayTitle,
                            axis: axis,
                            depth: depth + 1
                        ))
                    }
                    graph.edges.append(.init(
                        source: meaningNodeID,
                        target: senseNodeID,
                        kind: item.node.kind == .concept ? .expressesContent : .realizesFunction
                    ))
                }
            }
        }

        func traverseCategory(
            _ category: VocabularyCategory,
            parentNodeID: VocabularyGraphNodeID,
            depth: Int,
            visited: Set<UUID>
        ) {
            guard !visited.contains(category.id) else { return }
            let count = subtreeMeaningCount(category.id)
            let hasDirectOrSubtreeMatch = count > 0 || subtreeHasCategoryMatch(category.id)
            guard showsUnexplored || hasDirectOrSubtreeMatch || expanded.contains(category.id) else { return }

            let children = (childCategories[category.id] ?? []).filter { child in
                showsUnexplored || subtreeMeaningCount(child.id) > 0 || subtreeHasCategoryMatch(child.id) || expanded.contains(child.id)
            }
            let directMeanings = directMeaningsByCategory[category.id] ?? []
            let hasChildren = !children.isEmpty || !directMeanings.isEmpty
            // Auto-expand populated branches so the learner sees their semantic map immediately,
            // while keeping zero-count unexplored branches collapsed unless explicitly opened.
            let isExpanded = expanded.contains(category.id) || (!query.isEmpty && hasDirectOrSubtreeMatch) || (count > 0 && depth <= 2)
            let title = VocabularyClassificationPolicy.title(category, in: classification)
            let nodeID = VocabularyGraphNodeID.category(category.id)

            appendNode(.init(
                id: nodeID,
                label: title,
                axis: category.axis,
                depth: depth,
                itemCount: count,
                isUnexplored: count == 0,
                hasChildren: hasChildren,
                isExpanded: isExpanded
            ))
            if matchingCategoryIDs.contains(category.id) {
                graph.matches.insert(nodeID)
            }
            graph.edges.append(.init(
                source: parentNodeID,
                target: nodeID,
                kind: .taxonomy,
                isUnexplored: count == 0
            ))

            guard isExpanded else { return }
            var nextVisited = visited
            nextVisited.insert(category.id)
            for child in children {
                traverseCategory(child, parentNodeID: nodeID, depth: depth + 1, visited: nextVisited)
            }
            appendMeanings(directMeanings, under: nodeID, axis: category.axis, depth: depth + 1)
        }

        let axes: [VocabularyCategory.Axis] = {
            if let kind {
                return [kind == .function ? .function : .content]
            }
            return VocabularyCategory.Axis.allCases
        }()

        for axis in axes {
            let roots = categories.filter { $0.axis == axis && primaryParent[$0.id] == nil }
            let uncategorizedForAxis = items.filter {
                !categorizedMeaningIDs.contains($0.id) &&
                    (($0.node.kind == .function) == (axis == .function))
            }
            let visibleRoots = roots.filter { root in
                showsUnexplored || subtreeMeaningCount(root.id) > 0 || subtreeHasCategoryMatch(root.id) || expanded.contains(root.id)
            }
            guard !visibleRoots.isEmpty || !uncategorizedForAxis.isEmpty else { continue }

            let axisNodeID = VocabularyGraphNodeID.axis(axis)
            let axisMeaningCount = Set(visibleRoots.flatMap {
                VocabularyClassificationPolicy.meaningIDs(in: $0.id, index: classification).intersection(allMatchedMeaningIDs)
            }).count + uncategorizedForAxis.count
            let axisLabel = axisLabelText(for: axis)

            appendNode(.init(
                id: axisNodeID,
                label: axisLabel,
                axis: axis,
                depth: 0,
                itemCount: axisMeaningCount,
                isUnexplored: axisMeaningCount == 0,
                hasChildren: true,
                isExpanded: true
            ))

            for root in visibleRoots {
                traverseCategory(root, parentNodeID: axisNodeID, depth: 1, visited: [])
            }
            appendMeanings(uncategorizedForAxis, under: axisNodeID, axis: axis, depth: 1)
        }

        for relation in VocabularyMeaningBrowserProjection.confirmedRelations(in: index)
            where visibleMeaningIDs.contains(relation.sourceID) && visibleMeaningIDs.contains(relation.targetID) {
            graph.edges.append(.init(
                source: .meaning(relation.sourceID),
                target: .meaning(relation.targetID),
                kind: .init(rawValue: relation.kind.rawValue) ?? .related
            ))
        }

        assignTreePositions(in: &graph, columnSpacing: 260, rowSpacing: 54)
        return graph
    }

    /// Keeps catalog topology and text matching separate from the visible tree traversal.
    private static func categoryChildren(
        edges: [VocabularyCategoryParent],
        categoriesByID: [UUID: VocabularyCategory]
    ) -> ([UUID: UUID], [UUID: [VocabularyCategory]]) {
        var primaryParent: [UUID: UUID] = [:]
        for edge in edges where primaryParent[edge.categoryID] == nil {
            primaryParent[edge.categoryID] = edge.parentID
        }
        var childCategories: [UUID: [VocabularyCategory]] = [:]
        for (childID, parentID) in primaryParent {
            if let child = categoriesByID[childID] {
                childCategories[parentID, default: []].append(child)
            }
        }
        return (primaryParent, childCategories)
    }

    private static func matchingCategories(
        _ categories: [VocabularyCategory],
        classification: VocabularyClassificationIndex,
        query: String
    ) -> Set<UUID> {
        var matchingCategoryIDs = Set<UUID>()
        if !query.isEmpty {
            let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
            for category in categories {
                let effective = VocabularyClassificationPolicy.effective(category, in: classification)
                let categoryMatches = terms.allSatisfy { term in
                    VocabularyCategoryLocalizationPolicy.matches(effective, term: term)
                }
                if categoryMatches {
                    matchingCategoryIDs.insert(category.id)
                }
            }
        }
        return matchingCategoryIDs
    }

    private static func axisLabelText(for axis: VocabularyCategory.Axis) -> String {
        switch axis {
        case .content:
            return String(localized: "Content meanings", table: "Vocabulary")
        case .function:
            return String(localized: "Communicative functions", table: "Vocabulary")
        }
    }

    /// Computes a deterministic left-to-right hierarchical tidy tree layout so semantic categories,
    /// meaning groups, and expressions always appear at predictable spatial coordinates.
    private static func assignTreePositions(
        in graph: inout VocabularyGraphSnapshot,
        columnSpacing: CGFloat,
        rowSpacing: CGFloat
    ) {
        guard !graph.nodes.isEmpty else { return }
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let treeEdges = graph.edges.filter {
            $0.kind == .taxonomy || $0.kind == .expressesContent || $0.kind == .realizesFunction || $0.kind == .ownership
        }

        var children: [VocabularyGraphNodeID: [VocabularyGraphNodeID]] = [:]
        var hasParent = Set<VocabularyGraphNodeID>()
        var assignedParent = Set<VocabularyGraphNodeID>()
        for edge in treeEdges {
            guard nodesByID[edge.source] != nil, nodesByID[edge.target] != nil else { continue }
            if assignedParent.insert(edge.target).inserted {
                children[edge.source, default: []].append(edge.target)
                hasParent.insert(edge.target)
            }
        }

        let roots = graph.nodes.map(\.id).filter { !hasParent.contains($0) }
        var positions: [VocabularyGraphNodeID: CGPoint] = [:]
        var currentLeafY: CGFloat = 0
        var visited = Set<VocabularyGraphNodeID>()

        @discardableResult
        func layoutSubtree(_ id: VocabularyGraphNodeID, depth: Int) -> CGFloat {
            guard visited.insert(id).inserted else {
                return positions[id]?.y ?? currentLeafY
            }
            let columnX = CGFloat(depth) * columnSpacing
            let childIDs = (children[id] ?? []).filter { !visited.contains($0) }
            if childIDs.isEmpty {
                let leafY = currentLeafY
                // `VocabularyGraphCanvasView` uses flipped coordinates (`isFlipped == true`),
                // so +rowSpacing moves downward from top to bottom matching the sidebar outline.
                currentLeafY += rowSpacing
                positions[id] = CGPoint(x: columnX, y: leafY)
                return leafY
            }
            var childYs: [CGFloat] = []
            for childID in childIDs {
                childYs.append(layoutSubtree(childID, depth: depth + 1))
            }
            let midY = ((childYs.first ?? 0) + (childYs.last ?? 0)) / 2
            positions[id] = CGPoint(x: columnX, y: midY)
            return midY
        }

        for (index, root) in roots.enumerated() {
            if index > 0 {
                currentLeafY += rowSpacing * 0.85
            }
            layoutSubtree(root, depth: 0)
        }

        // Any remaining disconnected nodes get placed cleanly below the main tree.
        for node in graph.nodes where positions[node.id] == nil {
            positions[node.id] = CGPoint(x: CGFloat(node.depth) * columnSpacing, y: currentLeafY)
            currentLeafY += rowSpacing
        }

        // Center the entire tree around (0, 0) in world coordinates.
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
            let centerX = (minX + maxX) / 2
            let centerY = (minY + maxY) / 2
            for key in positions.keys {
                if let pt = positions[key] {
                    positions[key] = CGPoint(x: pt.x - centerX, y: pt.y - centerY)
                }
            }
        }

        graph.treePositions = positions
    }
}
