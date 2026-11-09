import Foundation
import LingroveNotebook

/// SQLite stores larger sense fields in separate rows for bounded edits. The split row
/// has no effect on corpus membership. Selection IDs are read only by the Dev migrator.
nonisolated struct VocabularySenseStorageRecord: Codable, Equatable, Identifiable, Sendable {
    var senseID: UUID
    var id: UUID { senseID }
    var interpretationIDs: [UUID] = []
    var isSavedWithoutContext = false
    var note = ""
    var tags: [String] = []
    var content: [VocabularyContentBlock]?
    var review: VocabularyReview?
    var reviewCards: [VocabularyReview]?
    var savedAt: Date?

    static func records(for document: VocabularyDocument) -> [Self] {
        document.catalog.flatMap(\.senses).map { sense in
            .init(senseID: sense.id,
                isSavedWithoutContext: sense.isSavedWithoutContext, note: sense.note, tags: sense.tags,
                content: sense.content, review: sense.review, reviewCards: sense.reviewCards,
                savedAt: sense.savedAt)
        }
    }

    static func materialize(_ records: [Self], in document: inout VocabularyDocument) throws {
        let bySense = Dictionary(grouping: records, by: \.senseID)
        guard records.count == document.catalog.reduce(0, { $0 + $1.senses.count }) else {
            throw VocabularyError.invalidArchive
        }
        for entry in document.catalog.indices {
            for index in document.catalog[entry].senses.indices {
                let id = document.catalog[entry].senses[index].id
                guard let values = bySense[id], values.count == 1, let record = values.first,
                      record.interpretationIDs.isEmpty else { throw VocabularyError.invalidArchive }
                record.apply(to: &document.catalog[entry].senses[index])
            }
        }
    }

    func apply(to sense: inout VocabularySense) {
        sense.isSavedWithoutContext = isSavedWithoutContext
        sense.note = note; sense.tags = tags; sense.content = content
        sense.review = review; sense.reviewCards = reviewCards
        sense.savedAt = savedAt
    }

    static func stripFields(from sense: inout VocabularySense) {
        sense.isSavedWithoutContext = false
        sense.note = ""; sense.tags = []; sense.content = nil
        sense.review = nil; sense.reviewCards = nil; sense.savedAt = nil
    }
}
