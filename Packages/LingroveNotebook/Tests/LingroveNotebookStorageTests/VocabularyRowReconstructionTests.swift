import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookPersistenceCodec

/// Reorganized decode/diff passes must retain the same admission boundary. These cases
/// exercise lost rows, contradictory headers/indexes and authored sequences, not timings.
struct VocabularyRowReconstructionTests {
    @Test func sharedIndexConsumesEveryRowAndRejectsHiddenChildrenAndOrphans() throws {
        let document = Self.fixture()
        let encoded = try VocabularyPersistenceCodec.encode(VocabularyEntrySaveState(validating: document))
        #expect(try VocabularyPersistenceCodec.decodeSaveState(.init(rows: encoded.rows.reversed(),
            reviewTemplatesPresent: true)).document == document)
        func replacing(_ row: VocabularyPersistenceRow) -> VocabularyPersistenceRows {
            .init(rows: encoded.rows.map { $0.key == row.key ? row : $0 }, reviewTemplatesPresent: true)
        }
        let header = try #require(encoded.rows.first { $0.entity == .entries })
        guard case var .entry(entry) = header.record.payload else { throw VocabularyError.invalidArchive }
        entry.senses = document.catalog[0].senses
        let hidden = try VocabularyPersistenceRow(record: .init(table: header.entity, id: header.id, parentID: nil,
            position: 0, payload: .entry(entry), extra: header.record.extra))
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decodeSaveState(replacing(hidden)) }
        let block = try #require(encoded.rows.first { $0.entity == .blocks })
        let orphan = try VocabularyPersistenceRow(record: .init(table: block.entity, id: block.id,
            parentID: UUID().uuidString, position: 0, payload: block.record.payload))
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decodeSaveState(replacing(orphan)) }
        let gapped = try VocabularyPersistenceRow(record: .init(table: block.entity, id: block.id,
            parentID: block.parentID, position: 8, payload: block.record.payload))
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decodeSaveState(replacing(gapped)) }
        var extra = header.record.extra; extra[0] = "contradictory lookup key"
        let wrongIndex = try VocabularyPersistenceRow(record: .init(table: header.entity, id: header.id,
            parentID: nil, position: 0, payload: header.record.payload, extra: extra))
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decodeSaveState(replacing(wrongIndex)) }
        let duplicate = VocabularyPersistenceRows(rows: encoded.rows + [header], reviewTemplatesPresent: true)
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decodeSaveState(duplicate) }
        let detached = VocabularyPersistenceRows(rows: encoded.rows.filter { $0.entity != .entries }, reviewTemplatesPresent: true)
        #expect(throws: (any Error).self) { try VocabularyEntryRowProjection(detached) }
    }

    @Test func unorderedFullDiffRetainsLiteralPayloadsAndAuthoredPositions() throws {
        let document = Self.fixture(), state = try VocabularyEntrySaveState(validating: document)
        let before = try VocabularyPersistenceCodec.encode(state)
        let projection = try VocabularyEntryRowProjection(before)
        let unchanged = try projection.replacingDocument(state)
        #expect(unchanged.changed.isEmpty && unchanged.removed.isEmpty && unchanged.repositioned.isEmpty)
        var edited = document
        edited.catalog[0].senses[0].note = "cafe\u{301}"
        edited.catalog[0].senses[0].content?.reverse()
        edited.catalog[0].senses[0].explanations.removeLast()
        let next = try VocabularyEntrySaveState(validating: edited)
        let change = try projection.replacingDocument(next)
        #expect(change.changed.contains { $0.entity == .collections })
        #expect(change.repositioned.filter { $0.entity == .blocks }.count == 2)
        #expect(change.removed.filter { $0.entity == .senseExplanations }.count == 1)
        let expected = try VocabularyPersistenceCodec.encode(next)
        #expect(try change.projection.rows(reviewTemplatesPresent: true).keyedRows() == expected.keyedRows())
        #expect(try VocabularyPersistenceCodec.decodeSaveState(change.projection.rows(reviewTemplatesPresent: true)).document == edited)
        #expect(try VocabularyPersistenceCodec.decodeSaveState(before).document == document)
    }

    private static func fixture() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 100)
        var sense = VocabularySense(id: UUID(), meaning: "A meaning", note: "caf\u{e9}", content: [
            .init(content: .text(.init(text: "First paragraph"))), .init(content: .text(.init(text: "Second paragraph")))
        ], createdAt: now, updatedAt: now)
        var entry = VocabularyEntry(id: UUID(), expression: "word", dictionaryForm: "", language: .english,
            kind: .word, senses: [], createdAt: now, updatedAt: now)
        let input = VocabularyExplanationIdentity.input(for: entry, sense: sense, example: nil)
        sense.explanations = (0..<2).map { index in
            .init(id: UUID(), input: input, language: .english, result: .init(meaning: "Meaning", explanation: "Explanation \(index)"),
                model: "Synthetic", createdAt: now.addingTimeInterval(Double(index)))
        }
        entry.senses = [sense]
        return .init(entries: [entry], reviewTemplates: [.init(id: UUID(), name: "Synthetic", layout: .init())])
    }
}
