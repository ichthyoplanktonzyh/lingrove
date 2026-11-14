import Foundation
import Testing
@testable import LingroveNotebook

/// Draft admission is stricter than reading existing data: a saved image-only sense remains
/// real content, while tags alone cannot turn an empty authoring draft into language material.
struct VocabularySenseContentPolicyTests {
    @Test func contentAdmissionKeepsImageOnlySensesAndRejectsTagOnlyDrafts() {
        let now = Date(timeIntervalSince1970: 100)
        var sense = VocabularySense(id: UUID(), meaning: " \n", tags: ["later"], createdAt: now, updatedAt: now)
        #expect(!VocabularySenseContentPolicy.hasContent(sense))
        sense.content = [.init(content: .text(.init(text: " \n")))]
        #expect(!VocabularySenseContentPolicy.hasContent(sense))
        sense.content = [.init(content: .image(.init(digest: String(repeating: "a", count: 64),
            width: 2, height: 1, byteCount: 100), caption: ""))]
        #expect(VocabularySenseContentPolicy.hasContent(sense))
    }

    @Test func manualCreationRequiresContentWithoutRequiringAnExample() throws {
        for input in [VocabularyEntryInput(expression: "word"),
                      .init(expression: "word", meaning: " \n", tags: ["later"])] {
            #expect(throws: VocabularyEntryInputError.self) { try VocabularyEntryInputPolicy.validated(input) }
        }
        #expect(try VocabularyEntryInputPolicy.validated(.init(expression: "word", meaning: "A meaning")).example.isEmpty)
        #expect(try VocabularyEntryInputPolicy.validated(.init(expression: "word", example: "A contextual example.")).meaning.isEmpty)
    }
}
