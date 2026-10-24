import Foundation

/// Typed rows separate durable relationships from flexible leaf values. The archive's SQLite
/// implementation owns these projections; no SQL handle or storage representation reaches UI.
nonisolated struct VocabularyDatabaseRecord: Equatable, Sendable {
    enum Table: String, CaseIterable, Sendable {
        case entries, senses, usages
        case senseExplanations = "sense_explanations", usageExplanations = "usage_explanations"
        case blocks, reviews, bindings, templates

        var parent: Self? {
            switch self {
            case .entries, .templates: nil
            case .senses: .entries
            case .usages, .senseExplanations, .blocks, .reviews: .senses
            case .usageExplanations: .usages
            case .bindings: .reviews
            }
        }
        var extraColumns: [String] {
            switch self {
            case .entries: ["lookup_key", "language", "expression"]
            case .senses: ["meaning"]
            default: []
            }
        }
    }

    struct Key: Hashable, Sendable { let table: Table; let id: String }

    /// JSON is restricted to one entity's scalar/leaf fields. Relationships and ordering live
    /// in SQL columns, while stripping children prevents a note edit from rewriting its usages.
    enum Payload: Equatable, Sendable {
        case entry(VocabularyEntry), sense(VocabularySense), usage(VocabularyExample)
        case explanation(LearningExplanationRecord), block(VocabularyContentBlock)
        case review(VocabularyReview), binding(AnkiNoteBinding), template(ReviewLayoutTemplate)

        func encoded() throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            switch self {
            case let .entry(value): return try encoder.encode(value)
            case let .sense(value): return try encoder.encode(value)
            case let .usage(value): return try encoder.encode(value)
            case let .explanation(value): return try encoder.encode(value)
            case let .block(value): return try encoder.encode(value)
            case let .review(value): return try encoder.encode(value)
            case let .binding(value): return try encoder.encode(value)
            case let .template(value): return try encoder.encode(value)
            }
        }

        static func decode(_ bytes: Data, table: Table) throws -> Self {
            let decoder = JSONDecoder()
            switch table {
            case .entries: return .entry(try decoder.decode(VocabularyEntry.self, from: bytes))
            case .senses: return .sense(try decoder.decode(VocabularySense.self, from: bytes))
            case .usages: return .usage(try decoder.decode(VocabularyExample.self, from: bytes))
            case .senseExplanations, .usageExplanations:
                return .explanation(try decoder.decode(LearningExplanationRecord.self, from: bytes))
            case .blocks: return .block(try decoder.decode(VocabularyContentBlock.self, from: bytes))
            case .reviews: return .review(try decoder.decode(VocabularyReview.self, from: bytes))
            case .bindings: return .binding(try decoder.decode(AnkiNoteBinding.self, from: bytes))
            case .templates: return .template(try decoder.decode(ReviewLayoutTemplate.self, from: bytes))
            }
        }
    }

    let table: Table
    let id: String
    let parentID: String?
    let position: Int
    let payload: Payload
    var extra: [String] = []
    var key: Key { .init(table: table, id: id) }
}
