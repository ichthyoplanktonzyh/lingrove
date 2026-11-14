import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// One browser index per loaded snapshot. It resolves labels (including merged senses) once
/// so sorting, searching and rendering rows don't scan the corpus for every comparison.
nonisolated struct BuiltInReviewContentState: Sendable {
    struct Source: Sendable {
        let expression: String
        let meaning: String
    }

    let hasCorpus: Bool
    private let groups: [UUID: LingroveNotebookReviewGroup]
    private let addable: [VocabularySelection]
    private let sources: [UUID: Source]
    private let version: LingroveNotebookVersion
    private let allSelections: [VocabularySelection]
    private let orderedGroups: [VocabularySelection]

    init(_ content: NotebookBuiltInReviewSnapshot, reusing previous: Self? = nil) {
        let currentGroups = content.review.groups, currentVersion = LingroveNotebookVersion(content.scope)
        groups = currentGroups; version = currentVersion
        let reusable = previous.flatMap { $0.version == currentVersion ? $0 : nil }
        let labels: [UUID: Source]
        let selections: [VocabularySelection]
        if let reusable {
            labels = reusable.sources; selections = reusable.allSelections
        } else {
            var indexed: [UUID: Source] = [:], selected: [VocabularySelection] = []
            for entry in content.scope.document.catalog {
                for sense in entry.senses {
                    let source = Source(expression: entry.expression, meaning: sense.meaning)
                    for id in [sense.id] + sense.mergedFrom where indexed[id] == nil { indexed[id] = source }
                    selected.append(.init(entryID: entry.id, senseID: sense.id))
                }
            }
            labels = indexed; selections = selected
        }
        sources = labels; allSelections = selections; hasCorpus = !selections.isEmpty
        addable = selections.filter { currentGroups[$0.senseID]?.cards.isEmpty != false }
        if let reusable, Set(currentGroups.keys) == Set(reusable.groups.keys) {
            orderedGroups = reusable.orderedGroups
        } else {
            orderedGroups = currentGroups.values.map(\.selection).sorted { lhs, rhs in
                let left = labels[lhs.senseID]?.expression ?? "", right = labels[rhs.senseID]?.expression ?? ""
                return left == right ? lhs.senseID.uuidString < rhs.senseID.uuidString
                    : left.localizedStandardCompare(right) == .orderedAscending
            }
        }
    }

    func source(for selection: VocabularySelection) -> Source? {
        sources[selection.senseID]
    }

    func selections(adding: Bool, filter: BuiltInReviewContentFilter, search: String) -> [VocabularySelection] {
        let candidates = adding ? sorted(addable) : orderedGroups.filter { selection in
            guard let group = groups[selection.senseID] else { return false }
            return filter == .attention ? group.hasUnavailableMaterial : group.status.rawValue == filter.rawValue
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { selection in
            guard let source = source(for: selection) else { return false }
            return source.expression.localizedCaseInsensitiveContains(query) || source.meaning.localizedCaseInsensitiveContains(query)
        }
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
