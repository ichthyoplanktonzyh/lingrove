import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

struct VocabularyLiteralSearchIndexTests {
    @Test func matchingPreservesLocalizedFieldsAndChangesFollowTheirOwner() throws {
        let now = Date()
        var entries = ["BANK", "café", "Straße", "ＦＯＯ", "银行", "Istanbul", "東京"].map { text in
            VocabularyEntry(id: UUID(), expression: text, dictionaryForm: text, language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: "A definition", note: "Personal annotation", createdAt: now, updatedAt: now)],
                createdAt: now, updatedAt: now)
        }
        var index = VocabularyLiteralSearchIndex(); index.prepare(entries)
        for query in ["", "bank", "cafe", "cafe\u{301}", "STRASSE", "foo", "银行", "istanbul", "東京", "definition annotation", "absent"] {
            #expect(index.matching(entries, query: query).map(\.id) == entries.filter { VocabularyPolicy.matches($0, query: query) }.map(\.id))
        }
        let removed = entries.removeFirst()
        entries[0].senses[0].content = [.init(content: .text(.init(text: "A newly indexed explanation")))]
        index.prepare(entries)
        #expect(index.matching(entries, query: "BANK").allSatisfy { $0.id != removed.id })
        #expect(index.matching(entries, query: "newly indexed").map(\.id) == [entries[0].id])
    }
}
