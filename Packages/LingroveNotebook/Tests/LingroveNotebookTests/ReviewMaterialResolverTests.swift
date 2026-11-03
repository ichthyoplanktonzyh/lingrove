import Foundation
import LingroveNotebook
import Testing

struct ReviewMaterialResolverTests {
    @Test func orderedSourcesAndOwnedBlocksRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 100)
        let example = VocabularyExample(id: UUID(), text: "take the take", translation: "translation",
            ranges: [.init(NSRange(location: 9, length: 4))], completeness: .sentence, meaning: "contextual", createdAt: now)
        let image = VocabularyImageReference(digest: String(repeating: "a", count: 64), width: 2, height: 1, byteCount: 100)
        let block = VocabularyContentBlock(content: .image(image, caption: "caption"))
        let sense = VocabularySense(id: UUID(), meaning: "meaning", meaningLanguage: .english, meaningOrigin: .user,
            note: "note", examples: [example], content: [block], createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "take", dictionaryForm: "take", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)
        let plan = ReviewMaterialPlan(name: "choice", layout: .init(front: [.init(source: .gapSentence), .init(source: .senseImage, blockID: block.id)],
            back: [.init(source: .meaning), .init(source: .translation), .init(source: .contextualMeaning), .init(source: .notes),
                   .init(source: .custom, content: [.init(content: .text(.init(text: "owned")))])]), exampleID: example.id)
        let encoded = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(ReviewMaterialPlan.self, from: encoded) == plan)
        let content = try ReviewMaterialResolver.resolve(entry: entry, sense: sense, plan: plan)
        #expect(content.front[0] == .text("take the ___"))
        #expect(content.front[1] == .blocks([.init(id: block.id, content: .image(image, caption: ""))]))
        #expect(Array(content.back.prefix(4)) == [.text("meaning"), .text("translation"), .text("contextual"), .text("note")])
        var removed = sense; removed.examples = []
        #expect(throws: ReviewMaterialError.missingContent(.gapSentence)) {
            try ReviewMaterialResolver.resolve(entry: entry, sense: removed, plan: plan)
        }
        let independent = ReviewMaterialPlan(layout: ReviewMaterialResolver.preset(0), exampleID: UUID())
        #expect(try ReviewMaterialResolver.resolve(entry: entry, sense: removed, plan: independent).front == [.text("take")])
    }

    @Test func gapsRejectInvalidUTF16AndWholeSentences() {
        #expect(ReviewMaterialResolver.gap(in: "🐈 take", ranges: [.init(NSRange(location: 1, length: 1))], kind: .word) == nil)
        #expect(ReviewMaterialResolver.gap(in: "take", ranges: [.init(NSRange(location: 0, length: 4))], kind: .word) == nil)
        #expect(ReviewMaterialResolver.gap(in: "take this", ranges: [.init(NSRange(location: 0, length: 4))], kind: .sentence) == nil)
    }

    @Test func mediaIsTypedAndAudioHashesExactBytes() {
        let digest = String(repeating: "a", count: 64)
        #expect(ReviewMaterialMediaReference(digest: digest, mimeType: "audio/wav", byteCount: 48).isValid)
        #expect(!ReviewMaterialMediaReference(digest: digest, mimeType: "audio/wav", byteCount: 48, width: 1).isValid)
        #expect(!ReviewMaterialMediaReference(digest: digest, mimeType: "text/html", byteCount: 48).isValid)
        #expect(ReviewMaterialAudio.textHash("café") != ReviewMaterialAudio.textHash("cafe\u{301}"))
    }
}
