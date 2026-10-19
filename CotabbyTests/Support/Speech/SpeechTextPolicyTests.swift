import Foundation
import Testing
@testable import Cotabby

/// Keeps spoken text aligned with what the learner clicked, including the hidden parts behind a
/// pattern's visual ellipses. These pure tests avoid requiring an installed voice or audio device.
@Suite
struct SpeechTextPolicyTests {
    @Test
    func wordsAndExpressionsUseTheirActualSurface() {
        let word = unit(surface: "went", query: "go", kind: .word)
        let expression = unit(surface: "look forward to", query: "look forward to", kind: .expression)

        #expect(SpeechTextPolicy.spokenText(for: word) == "went")
        #expect(SpeechTextPolicy.spokenText(for: expression) == "look forward to")
    }

    @Test
    func patternSpeaksAllWordsAndPronounSlotsWithoutDisplayEllipses() {
        let pattern = LearningUnit(
            id: 0, surface: "take … time", query: "take one's time", kind: .pattern,
            ranges: [], words: [
                .init(text: "take", range: NSRange(location: 0, length: 4)),
                .init(text: "your", range: NSRange(location: 5, length: 4)),
                .init(text: "time", range: NSRange(location: 10, length: 4))
            ]
        )

        #expect(SpeechTextPolicy.spokenText(for: pattern) == "take your time")
    }

    @Test
    func malformedOrEmptyUnitsProduceNoUtterance() {
        let emptyWord = unit(surface: "  ", query: "something", kind: .word)
        let emptyPattern = LearningUnit(
            id: 0, surface: "take … time", query: "take one's time", kind: .pattern,
            ranges: [], words: []
        )
        let malformedPattern = LearningUnit(
            id: 0, surface: "take … time", query: "take one's time", kind: .pattern,
            ranges: [], words: [.init(text: "take", range: .init(location: 0, length: 4)),
                                .init(text: " ", range: .init(location: 5, length: 1))]
        )

        #expect(SpeechTextPolicy.spokenText(for: emptyWord) == nil)
        #expect(SpeechTextPolicy.spokenText(for: emptyPattern) == nil)
        #expect(SpeechTextPolicy.spokenText(for: malformedPattern) == nil)
        #expect(SpeechTextPolicy.sanitizedText("\u{0000}\u{0007}") == nil)
    }

    @Test
    func directSpeechTextIsCollapsedAndBounded() {
        let raw = String(repeating: "hello ", count: SpeechTextPolicy.maximumLength)
        let spoken = SpeechTextPolicy.sanitizedText(" \n hello\t world \n")
        let bounded = SpeechTextPolicy.sanitizedText(raw)

        #expect(spoken == "hello world")
        #expect(bounded?.count == SpeechTextPolicy.maximumLength)
    }

    private func unit(surface: String, query: String, kind: LearningUnit.Kind) -> LearningUnit {
        .init(id: 0, surface: surface, query: query, kind: kind, ranges: [], words: [])
    }
}
