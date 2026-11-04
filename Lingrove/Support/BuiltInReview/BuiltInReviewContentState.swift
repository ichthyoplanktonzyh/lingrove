import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// One browser index per loaded snapshot. It resolves labels (including merged senses) once
/// so sorting, searching and rendering rows don't scan the corpus for every comparison.
nonisolated struct BuiltInReviewContentState {
    struct Source {
        let expression: String
        let meaning: String
    }

    let hasCorpus: Bool
    private let groups: [UUID: LingroveNotebookReviewGroup]
    private let addable: [VocabularySelection]
    private let sources: [UUID: Source]

    init(_ content: NotebookBuiltInReviewSnapshot) {
        groups = content.review.groups
        let document = content.scope.document
        let collectedIDs = Set(document.collections.map(\.senseID))
        var hasCorpus = false
        var addable: [VocabularySelection] = []
        var sources: [UUID: Source] = [:]
        // List rows only need lexical labels and collection membership. Joining source
        // examples and media would allocate values this browser never uses.
        for entry in document.catalog {
            for sense in entry.senses {
                let source = Source(expression: entry.expression, meaning: sense.meaning)
                for id in [sense.id] + sense.mergedFrom where sources[id] == nil {
                    sources[id] = source
                }
                if collectedIDs.contains(sense.id) {
                    hasCorpus = true
                    if groups[sense.id]?.cards.isEmpty != false {
                        addable.append(.init(entryID: entry.id, senseID: sense.id))
                    }
                }
            }
        }
        self.sources = sources
        self.hasCorpus = hasCorpus
        self.addable = addable
    }

    func source(for selection: VocabularySelection) -> Source? {
        sources[selection.senseID]
    }

    func selections(adding: Bool, filter: BuiltInReviewContentFilter, search: String) -> [VocabularySelection] {
        let candidates = adding ? addable : groups.values.compactMap { group in
            let included = filter == .attention ? group.hasUnavailableMaterial : group.status.rawValue == filter.rawValue
            return included ? group.selection : nil
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted(candidates) }
        return sorted(candidates.filter { selection in
            guard let source = source(for: selection) else { return false }
            return source.expression.localizedCaseInsensitiveContains(query) || source.meaning.localizedCaseInsensitiveContains(query)
        })
    }

    /// Batch picks survive a search change, but must still belong to the addable snapshot.
    func selectedForEnrollment(_ ids: Set<UUID>) -> [VocabularySelection] {
        guard !ids.isEmpty else { return [] }
        return sorted(addable.filter { ids.contains($0.senseID) })
    }

    private func sorted(_ candidates: [VocabularySelection]) -> [VocabularySelection] {
        candidates.sorted { lhs, rhs in
            let left = source(for: lhs)?.expression ?? ""
            let right = source(for: rhs)?.expression ?? ""
            return left == right ? lhs.senseID.uuidString < rhs.senseID.uuidString
                : left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}
