import Foundation
import LingroveNotebook
import Testing

struct VocabularyInlineFormattingTests {
    @Test func formatsOnlySelectedTextAndEscapesHTML() throws {
        let text = VocabularyTextContent(text: "one <two> three", runs: [.init(location: 4, length: 5, bold: true, italic: true)])
        let block = VocabularyContentBlock(content: .text(text))
        try VocabularyContentPolicy.validate([block])
        #expect(ReviewNoteProjection.richHTML([block]) == "<p>one <em><strong>&lt;two&gt;</strong></em> three</p>")
        let data = try JSONEncoder().encode(block)
        #expect(try JSONDecoder().decode(VocabularyContentBlock.self, from: data) == block)
    }
    @Test func rejectsSplitUnicodeOverlapsAndOutOfBoundsMarks() {
        for runs in [
            [VocabularyTextRun(location: 1, length: 1, bold: true)],
            [.init(location: 0, length: 2, bold: true), .init(location: 1, length: 2, italic: true)],
            [.init(location: 0, length: 200, bold: true)]
        ] {
            #expect(throws: VocabularyError.invalidContent) {
                try VocabularyContentPolicy.validate([.init(content: .text(.init(text: "🐈cat", runs: runs)))])
            }
        }
    }
}
