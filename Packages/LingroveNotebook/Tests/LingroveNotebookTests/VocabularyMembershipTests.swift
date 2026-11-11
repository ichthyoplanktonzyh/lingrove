import Foundation
import Testing
import LingroveNotebook

/// Business equivalence ignores permutations of corpus members, while authored structure,
/// identity and references remain content. These assertions do not depend on SQL row order.
struct VocabularyMembershipTests {
    @Test func permutationIsTheSameCorpusButBodyOrderAndMembershipStillMatter() throws {
        let now = Date(), early = UUID(), late = UUID()
        let examples = [early, late].enumerated().map { offset, id in
            VocabularyExample(id: id, sourceKind: .authored, text: "Example \(offset)", translation: "", ranges: [],
                completeness: .sentence, meaning: "", createdAt: now.addingTimeInterval(Double(offset)))
        }
        let blocks = ["First paragraph", "Second paragraph"].map { VocabularyContentBlock(content: .text(.init(text: $0))) }
        let sense = VocabularySense(id: UUID(), meaning: "A sense", tags: ["one", "two"], examples: examples,
            content: blocks, createdAt: now, updatedAt: now)
        let other = VocabularySense(id: UUID(), meaning: "Another sense", createdAt: now.addingTimeInterval(1), updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "word", dictionaryForm: "word", language: .english, kind: .word,
            senses: [sense, other], createdAt: now, updatedAt: now)
        let original = VocabularyDocument(entries: [entry])
        var permuted = original
        permuted.catalog[0].senses.reverse(); permuted.interpretations.reverse()
        permuted.sources.reverse(); permuted.occurrences.reverse()
        #expect(original == permuted)
        #expect(original.entries == permuted.entries)
        #expect(permuted.entries[0].defaultSense?.id == sense.id)
        #expect(permuted.entries[0].senses.first { $0.id == sense.id }?.defaultExample?.id == early)
        let owner = try #require(permuted.catalog[0].senses.firstIndex { $0.id == sense.id })
        permuted.catalog[0].senses[owner].content?.reverse()
        #expect(original != permuted)
        permuted = original; permuted.interpretations.removeLast()
        #expect(original != permuted)
        permuted = original; permuted.catalog[0].senses.append(sense)
        #expect(throws: (any Error).self) { try VocabularyDocumentValidation.validate(permuted) }
    }
}
