import Combine
import Foundation
import LingroveNotebook

/// A notebook view owns this bounded memo of its current browsing projection. It deliberately
/// publishes no state: SwiftUI's store/filter inputs drive rendering, and repeated reads within
/// that render reuse immutable arrays. Selecting or expanding a row cannot invalidate content.
@MainActor
final class VocabularyBrowserCache: ObservableObject {
    struct Key: Equatable {
        let revision: UUID
        let language: LearningLanguage?
        let tag: String
        let newestFirst: Bool
    }
    private var key: Key?
    private var scoped: [VocabularyEntry] = []
    private var literalQuery: String?
    private var literal: [VocabularyEntry] = []
    private var meaningQuery: String?
    private var meaningLanguages: [LearningLanguage] = []
    private var meanings: [VocabularyMeaningBrowserProjection.Item] = []
    private var unclassifiedQuery: String?
    private var other: [VocabularySelection] = []
    private var expandedRows: Set<UUID>?
    private var rows: [VocabularyBrowserRow] = []

    func entries(store: VocabularyStore, language: LearningLanguage?, tag: String, newestFirst: Bool) -> [VocabularyEntry] {
        let next = Key(revision: store.contentRevision, language: language, tag: tag, newestFirst: newestFirst)
        guard key != next else { return scoped }
        key = next; literalQuery = nil; meaningQuery = nil; unclassifiedQuery = nil; expandedRows = nil
        scoped = store.entries.compactMap { entry in
            guard language == nil || entry.language == language else { return nil }
            var value = entry
            if !tag.isEmpty { value.senses.removeAll { !$0.tags.contains(tag) } }
            return value.senses.isEmpty ? nil : value
        }.sorted {
            // Creation order keeps an edited note in place. A stable identity tie-breaker also
            // prevents equal-timestamp imports from shuffling when another entry is saved.
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
        }
        return scoped
    }

    func matching(_ entries: [VocabularyEntry], query: String) -> [VocabularyEntry] {
        if literalQuery != query {
            expandedRows = nil
            literalQuery = query
            literal = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entries :
                entries.filter { VocabularyPolicy.matches($0, query: query) }
        }
        return literal
    }

    func listRows(entries: [VocabularyEntry], expanded: Set<UUID>) -> [VocabularyBrowserRow] {
        guard expandedRows != expanded else { return rows }
        expandedRows = expanded
        rows = entries.flatMap { entry -> [VocabularyBrowserRow] in
            if entry.senses.count == 1, let sense = entry.senses.first {
                return [.init(entry: entry, sense: sense, senseNumber: 1)]
            }
            let header = VocabularyBrowserRow(entry: entry, sense: nil, senseNumber: 0)
            guard expanded.contains(entry.id) else { return [header] }
            return [header] + entry.senses.enumerated().map {
                .init(entry: entry, sense: $0.element, senseNumber: $0.offset + 1)
            }
        }
        return rows
    }

    func meanings(store: VocabularyStore, entries: [VocabularyEntry], query: String,
                  includeEmpty: Bool, languages: [LearningLanguage]) -> [VocabularyMeaningBrowserProjection.Item] {
        if meaningQuery != query || meaningLanguages != languages {
            meaningQuery = query; meaningLanguages = languages
            meanings = VocabularyMeaningBrowserProjection.items(index: store.semantics, entries: entries, query: query,
                includeEmpty: includeEmpty, preferredLanguages: languages)
        }
        return meanings
    }

    func unclassified(store: VocabularyStore, entries: [VocabularyEntry], query: String) -> [VocabularySelection] {
        if unclassifiedQuery != query {
            unclassifiedQuery = query
            other = VocabularyMeaningBrowserProjection.unclassified(index: store.semantics,
                entries: matching(entries, query: query))
        }
        return other
    }
}
