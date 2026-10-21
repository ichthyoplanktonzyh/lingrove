import Foundation

/// Converts the filtered notebook into headword dots and explicitly owned sense branches.
/// Search can reveal a matching sense, but proximity, spelling and model text never create edges.
nonisolated enum VocabularyGraphProjection {
    static func make(entries: [VocabularyEntry], expanded: Set<UUID>, query: String) -> VocabularyGraphSnapshot {
        var graph = VocabularyGraphSnapshot()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        graph.searchQuery = query
        for entry in entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let parent = VocabularyGraphNodeID.headword(entry.id)
            graph.nodes.append(.init(id: parent, label: entry.expression))
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
}
