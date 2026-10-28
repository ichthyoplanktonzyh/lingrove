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
                         preferredLanguages: [LearningLanguage] = []) -> VocabularyGraphSnapshot {
        var graph = VocabularyGraphSnapshot()
        graph.isMeaningGraph = true; graph.searchQuery = query
        let items = VocabularyMeaningBrowserProjection.items(index: index, entries: entries, query: query,
            kind: kind, includeEmpty: includeEmpty, preferredLanguages: preferredLanguages)
        let visible = Set(items.map(\.id))
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var included = Set<VocabularyGraphNodeID>()
        let mixedLanguages = VocabularyMeaningLabelPolicy.hasMultipleLanguages(entries)
        for item in items {
            let root = VocabularyGraphNodeID.meaning(item.id)
            graph.nodes.append(.init(id: root, label: item.title, meaningKind: item.node.kind))
            graph.headwordCount += 1
            if !query.isEmpty { graph.matches.insert(root) }
            guard expanded.contains(item.id) || !query.isEmpty else { continue }
            for selection in item.selections {
                guard let entry = entriesByID[selection.entryID], let sense = entry.senses.first(where: { $0.id == selection.senseID })
                else { continue }
                let child = VocabularyGraphNodeID.sense(selection)
                if included.insert(child).inserted {
                    let expression = VocabularyMeaningLabelPolicy.expressionTitle(entry, includeLanguage: mixedLanguages)
                    graph.nodes.append(.init(id: child, label: expression + " · " + sense.displayTitle))
                }
                graph.edges.append(.init(source: root, target: child,
                    kind: item.node.kind == .concept ? .expressesContent : .realizesFunction))
            }
        }
        for relation in VocabularyMeaningBrowserProjection.confirmedRelations(in: index)
            where visible.contains(relation.sourceID) && visible.contains(relation.targetID) {
            graph.edges.append(.init(source: .meaning(relation.sourceID), target: .meaning(relation.targetID),
                kind: .init(rawValue: relation.kind.rawValue) ?? .related))
        }
        return graph
    }
}
