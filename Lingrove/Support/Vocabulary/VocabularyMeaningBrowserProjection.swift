import Foundation

/// Both meaning views consume this projection. Search follows labels and explicit cues to
/// senses, without making a translation, tag or matching substring into a new semantic edge.
nonisolated enum VocabularyMeaningBrowserProjection {
    struct Item: Identifiable, Equatable, Sendable {
        let node: VocabularyMeaningNode
        let title: String
        let selections: [VocabularySelection]
        let pendingCount: Int
        var id: UUID { node.id }
    }

    static func items(index: VocabularySemanticIndex, entries: [VocabularyEntry], query: String = "",
                      kind: VocabularyMeaningNode.Kind? = nil, includeEmpty: Bool = true,
                      preferredLanguages: [LearningLanguage] = []) -> [Item] {
        let senses = Dictionary(uniqueKeysWithValues: entries.flatMap { entry in
            entry.senses.map { ($0.id, VocabularySelection(entryID: entry.id, senseID: $0.id)) }
        })
        let mappings = Dictionary(grouping: index.mappings.filter { senses[$0.senseID] != nil }, by: \.nodeID)
        let cueIDs = Set(index.cues.filter { matches($0.text, query) }.map(\.id))
        let cueNodes = Set(index.cueTargets.filter {
            $0.provenance.status == .confirmed && cueIDs.contains($0.cueID)
        }.map(\.nodeID))
        let matchingSenses = Set(entries.flatMap { entry in entry.senses.compactMap { sense -> UUID? in
            var value = entry; value.senses = [sense]
            return VocabularyPolicy.matches(value, query: query) ? sense.id : nil
        } })
        let matchingPatterns = Set(index.patterns.filter {
            $0.provenance.status == .confirmed &&
                matches($0.template + " " + $0.note + " " + $0.collocations.joined(separator: " "), query)
        }.map(\.senseID))
        return index.nodes.compactMap { node -> Item? in
            guard kind == nil || node.kind == kind else { return nil }
            let links = mappings[node.id] ?? []
            guard includeEmpty || !links.isEmpty else { return nil }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                node.labels.contains(where: { matches($0.text, query) }) || matches(node.definition, query) ||
                matches(node.scopeNote, query) || cueNodes.contains(node.id) || links.contains(where: {
                    $0.provenance.status == .confirmed && (matchingSenses.contains($0.senseID) ||
                        matchingPatterns.contains($0.senseID) || matches($0.conditions + " " + $0.nuance, query))
                }) else { return nil }
            var seen = Set<UUID>()
            let confirmed = links.filter { $0.provenance.status == .confirmed && seen.insert($0.senseID).inserted }
            return .init(node: node, title: node.title(in: preferredLanguages), selections: confirmed.compactMap { senses[$0.senseID] },
                pendingCount: links.filter { $0.provenance.status == .proposed }.count)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func unclassified(index: VocabularySemanticIndex, entries: [VocabularyEntry]) -> [VocabularySelection] {
        let linked = Set(index.mappings.filter { $0.provenance.status == .confirmed }.map(\.senseID))
        return entries.flatMap { entry in entry.senses.filter { !linked.contains($0.id) }.map {
            .init(entryID: entry.id, senseID: $0.id)
        } }
    }

    /// List details and graph edges share the same assertion boundary. Candidate relations
    /// stay in the archive for maintenance without becoming navigation facts in either view.
    static func confirmedRelations(in index: VocabularySemanticIndex) -> [VocabularyMeaningRelation] {
        index.relations.filter { $0.provenance.status == .confirmed }
    }

    static func matches(_ value: String, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedStandardContains(query)
    }
}
