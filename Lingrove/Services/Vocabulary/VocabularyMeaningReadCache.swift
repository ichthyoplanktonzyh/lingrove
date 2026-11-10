import Combine
import Foundation
import LingroveNotebook

/// A detail view keeps one scoped, localized meaning projection for its lifetime. Headers,
/// counts and cards read that same result; UI-only changes such as opening an editor no longer
/// rebuild every semantic group. The store still owns all durable values and mutations.
@MainActor
final class VocabularyMeaningReadCache: ObservableObject {
    private var revision: UUID?
    private var entries: [VocabularyEntry] = []
    private var languages: [LearningLanguage] = []
    private var items: [VocabularyMeaningBrowserProjection.Item] = []
    private var categoryID: UUID?
    private var categoryItems: [VocabularyMeaningBrowserProjection.Item] = []

    func category(_ id: UUID, store: VocabularyStore, entries: [VocabularyEntry],
                  languages: [LearningLanguage]) -> [VocabularyMeaningBrowserProjection.Item] {
        if revision != store.contentRevision || self.entries != entries || self.languages != languages {
            revision = store.contentRevision; self.entries = entries; self.languages = languages; categoryID = nil
            items = VocabularyMeaningBrowserProjection.items(index: store.semantics, entries: entries,
                includeEmpty: true, preferredLanguages: languages)
        }
        if categoryID != id {
            categoryID = id
            let direct = Set(store.classification.memberships.filter {
                $0.categoryID == id && $0.provenance.status == .confirmed
            }.map(\.nodeID))
            let inherited = VocabularyClassificationPolicy.meaningIDs(in: id, index: store.classification).subtracting(direct)
            categoryItems = items.filter { direct.contains($0.id) } + items.filter { inherited.contains($0.id) }
        }
        return categoryItems
    }
}
