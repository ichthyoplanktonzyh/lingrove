import Foundation
import Testing
@testable import Cotabby

struct ReviewCardPolicyTests {
    @Test func discontinuousGapUsesTheStoredOccurrenceAndPreservesUnicode() throws {
        let text = "🐟 Please keep me posted; keep it safe."
        let source = text as NSString
        let ranges = [source.range(of: "keep"), source.range(of: "posted")].map(VocabularyTextRange.init)
        let gap = try #require(ReviewCardPolicy.gap(in: text, ranges: ranges, kind: .pattern))
        #expect(gap.prompt == "🐟 Please ___ me ___; keep it safe.")
        #expect(gap.answer == "keep … posted")
        #expect(ReviewCardPolicy.gap(in: text, ranges: ranges + [ranges[0]], kind: .pattern) == nil)
        #expect(ReviewCardPolicy.gap(in: text, ranges: ranges, kind: .sentence) == nil)
        #expect(ReviewCardPolicy.gap(in: text, ranges: [.init(NSRange(location: 1, length: 1))], kind: .word) == nil)
    }

    @Test(arguments: ["https://127.0.0.1:8765", "http://example.com", "http://127.0.0.1@evil.com", "http://localhost/a",
                      "http://localhost?secret=x", "http://localhost#x", "http://localhost:0"])
    func connectionNeverBroadensToAnotherHost(_ text: String) { #expect(AnkiReviewPolicy.endpoint(text) == nil) }

    @Test func htmlIsEscapedBeforeHighlightingAndMappingsCannotOverwriteIdentity() throws {
        let content = ReviewCardContent(expression: "<script>", answer: "meaning & detail", sentence: "<script>",
            ranges: [.init(NSRange(location: 0, length: 8))], translation: "", explanation: "", notes: "", gapPrompt: "", gapAnswer: "",
            recognition: true, gap: false)
        let id = UUID()
        let fields = try AnkiReviewPolicy.fields(content: content, identity: id, mapping: AnkiReviewPolicy.presetMapping,
            overrides: ["LingroveID": "some-other-sense", "Unmapped": "foreign"])
        #expect(fields["LingroveID"] == id.uuidString.lowercased())
        #expect(fields["Sentence"] == "<b>&lt;script&gt;</b>")
        #expect(fields["Unmapped"] == nil)
        #expect(fields["GapPrompt"]?.isEmpty == true)
    }

    @Test func emptyLegacyReviewExtensionStillDecodesAsSchemaThree() throws {
        let now = Date()
        let entry = VocabularyEntry(id: UUID(), expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            senses: [.init(id: UUID(), meaning: "", createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
        let data = try JSONEncoder().encode(VocabularyDocument(entries: [entry]))
        let decoded = try JSONDecoder().decode(VocabularyDocument.self, from: data)
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.entries[0].senses[0].review == nil)
    }
}
