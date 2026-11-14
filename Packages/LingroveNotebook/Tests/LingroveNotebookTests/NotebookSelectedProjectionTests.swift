import Foundation
import Testing
@testable import LingroveNotebook

struct NotebookSelectedProjectionTests {
    @Test func selectedProjectionMatchesCompleteValuesAndRejectsOtherSenses() throws {
        let now = Date(timeIntervalSince1970: 123)
        let entries = ["bank", "shore"].map { word in
            VocabularyEntry(id: UUID(), expression: word, dictionaryForm: word, language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: "Meaning of \(word)",
                    examples: [.init(id: UUID(), text: "A \(word) in context.", translation: "A translation",
                        ranges: [], completeness: .sentence, meaning: "", createdAt: now)], createdAt: now, updatedAt: now)],
                createdAt: now, updatedAt: now)
        }
        let document = VocabularyDocument(entries: entries)
        let first = entries[0], other = entries[1].senses[0].id
        let complete = NotebookSenseProjection(document)
        let selected = NotebookSenseProjection(document, selecting: Set(first.senses.map(\.id)))
        #expect(try selected.entry(first) == complete.entry(first))
        #expect(try selected.senses().count == 1)
        #expect(throws: NotebookToolError.self) { try selected.sense(other) }
        #expect(throws: NotebookToolError.self) { try selected.entry(entries[1]) }
    }
}
