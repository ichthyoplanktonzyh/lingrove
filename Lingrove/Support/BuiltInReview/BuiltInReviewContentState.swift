import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// Pure list projection shared by management and the add flow. Existing participation is
/// restored through its own action, never duplicated by a second enrollment from this picker.
nonisolated enum BuiltInReviewContentState {
    static func selections(in content: NotebookBuiltInReviewSnapshot, adding: Bool,
                           filter: BuiltInReviewContentFilter, search: String) -> [VocabularySelection] {
        let values: [VocabularySelection]
        if adding {
            values = content.scope.document.collectedEntries.flatMap { entry in
                entry.senses.filter { content.review.groups[$0.id]?.cards.isEmpty != false }
                    .map { .init(entryID: entry.id, senseID: $0.id) }
            }
        } else {
            values = content.review.groups.values.filter { group in
                filter == .attention ? group.hasUnavailableMaterial : group.status.rawValue == filter.rawValue
            }.map(\.selection)
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return values.filter { selection in
            let source = BuiltInReviewSource.value(selection, in: content.scope)
            return query.isEmpty || source?.entry.expression.localizedCaseInsensitiveContains(query) == true
                || source?.sense.meaning.localizedCaseInsensitiveContains(query) == true
        }.sorted { lhs, rhs in
            let left = BuiltInReviewSource.value(lhs, in: content.scope)?.entry.expression ?? ""
            let right = BuiltInReviewSource.value(rhs, in: content.scope)?.entry.expression ?? ""
            return left == right ? lhs.senseID.uuidString < rhs.senseID.uuidString
                : left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}
