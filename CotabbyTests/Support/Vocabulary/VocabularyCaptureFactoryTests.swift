import Foundation
import Testing
@testable import Cotabby

@MainActor
struct VocabularyCaptureFactoryTests {
    @Test func originalReadingWordRetainsExactContextOccurrenceAndItsTranslation() throws {
        let text = "🙂 Please keep me posted; previously posted notes remain."
        let occurrence = (text as NSString).range(of: "posted", options: .backwards)
        var preview = LearningSentencePresentation(id: UUID(), source: "posted", translation: "发布过的", chunks: [],
            sourceLanguage: .english, targetLanguage: .chinese, caret: .zero, isExpanded: true, isGenerating: false,
            message: "", previousTranslation: nil, shortcutLabel: "", readingSource: .pointer)
        preview.vocabularyContext = VocabularyPolicy.example(text: text, ranges: [occurrence], language: .english)
        let unit = LearningUnit.word(.init(text: "posted", range: .init(location: 0, length: 6)))
        let capture = try #require(VocabularyCaptureFactory.unit(unit, in: preview, original: true))
        #expect(capture.language == .english && capture.meaningLanguage == .chinese)
        #expect(capture.meaning == "发布过的")
        #expect(capture.example?.text == text && capture.example?.translation.isEmpty == true)
        #expect(capture.example?.ranges == preview.vocabularyContext?.ranges)
    }

    @Test func wordCaptureIncludesFixedSentenceAndTranslationWithoutDictionaryRequest() throws {
        let preview = presentation()
        let word = LearningDictionaryWord(text: "posted", range: (preview.translation as NSString).range(of: "posted"))
        let capture = try #require(VocabularyCaptureFactory.unit(.word(word), in: preview))
        #expect(capture.expression == "posted")
        #expect(capture.example?.text == preview.translation)
        #expect(capture.example?.translation == preview.source)
        #expect(capture.meaning.isEmpty)
        #expect(capture.definitions.isEmpty)
    }

    @Test func staleAndStreamingResultsCannotBeSaved() {
        var preview = presentation()
        preview.isStale = true
        #expect(VocabularyCaptureFactory.preview(preview) == nil)
        preview.isStale = false
        preview.isTranslating = true
        #expect(VocabularyCaptureFactory.preview(preview) == nil)
    }

    @Test func readingWordTranslationIsNotMistakenForSentenceTranslation() throws {
        var preview = presentation()
        preview = LearningSentencePresentation(id: preview.id, source: "posted", translation: "告知", chunks: [],
            sourceLanguage: .english, targetLanguage: .chinese, caret: .zero, isExpanded: false, isGenerating: false,
            message: "", previousTranslation: nil, shortcutLabel: "", readingSource: .pointer)
        preview.vocabularyContext = VocabularyPolicy.example(text: "Please keep me posted.",
            ranges: [NSRange(location: 15, length: 6)], language: .english)
        let capture = try #require(VocabularyCaptureFactory.preview(preview))
        #expect(capture.language == .english && capture.kind == .word)
        #expect(capture.example?.translation.isEmpty == true)
        #expect(capture.example?.meaning == "告知")
    }

    @Test func snapshotRemainsIndependentOfLaterPresentation() throws {
        var preview = presentation()
        let capture = try #require(VocabularyCaptureFactory.preview(preview))
        preview = LearningSentencePresentation(id: UUID(), source: "Different", translation: "Other", chunks: [],
            sourceLanguage: .english, targetLanguage: .chinese, caret: .zero, isExpanded: false, isGenerating: false,
            message: "", previousTranslation: nil, shortcutLabel: "")
        #expect(capture.expression == "Please keep me posted.")
        #expect(capture.meaning == "请随时告诉我最新进展。")
    }

    @Test func repeatedComponentButtonsKeepTheirExactOccurrence() throws {
        let text = "Time after time, we wait."
        let words = LearningUnitPolicy.words(in: text, language: .english)
        let unit = LearningUnit(id: 1, surface: "Time after time", query: "time after time", kind: .expression,
            ranges: [NSRange(location: 0, length: 15)], words: Array(words.prefix(3)))
        let capture = VocabularyCapture(expression: unit.surface, dictionaryForm: unit.query, language: .english, kind: .expression,
            example: VocabularyPolicy.example(text: text, ranges: unit.ranges, language: .english))
        let clicked = try #require(unit.words.last)
        let result = try #require(VocabularyCaptureFactory.component(clicked, unit: unit, capture: capture))
        #expect(result.expression == "time")
        #expect(result.example?.ranges == [VocabularyTextRange(clicked.range)])
    }

    @Test func patternSavesCanonicalExpressionWithItsActualSentence() throws {
        let preview = presentation()
        let ranges = ["keep", "posted"].map { (preview.translation as NSString).range(of: $0) }
        let unit = LearningUnit(id: 1, surface: "keep me posted", query: "keep someone posted", kind: .pattern,
            ranges: ranges, words: [])
        let capture = try #require(VocabularyCaptureFactory.unit(unit, in: preview))
        #expect(capture.expression == "keep someone posted")
        #expect(capture.example?.text == "Please keep me posted.")
        #expect(capture.example?.ranges.count == 2)
    }

    private func presentation() -> LearningSentencePresentation {
        LearningSentencePresentation(id: UUID(), source: "请随时告诉我最新进展。", translation: "Please keep me posted.", chunks: [],
            sourceLanguage: .chinese, targetLanguage: .english, caret: .zero, isExpanded: false, isGenerating: false,
            message: "", previousTranslation: nil, shortcutLabel: "")
    }
}
