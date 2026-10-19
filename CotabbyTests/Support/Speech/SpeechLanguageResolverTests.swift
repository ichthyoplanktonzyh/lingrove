import Foundation
import NaturalLanguage
import Testing
@testable import Cotabby

/// Deterministic score tests cover policy boundaries; a small set of real recognizer examples
/// catches BCP-47 mapping and script regressions without requiring a voice, model or network.
@Suite struct SpeechLanguageResolverTests {
    @Test(arguments: [
        ("Please keep me posted on the progress.", LearningLanguage.english),
        ("你好，这是今天的语音试听。", .chinese),
        ("Bonjour, comment allez-vous aujourd’hui ?", .french),
        ("Esta es una frase para escuchar en español.", .spanish),
        ("これは日本語の音声テストです。", .japanese),
        ("안녕하세요. 오늘의 음성 테스트입니다.", .korean)
    ])
    func actualTextOverridesTheCardHint(text: String, expected: LearningLanguage) {
        let hint: LearningLanguage = expected == .english ? .chinese : .english
        #expect(SpeechLanguageResolver.resolve(text: text, hint: hint) == expected)
    }

    @Test
    func confidentTextWinsWithoutExaminingUnrelatedContext() {
        var samples: [String] = []
        let language = SpeechLanguageResolver.resolve(text: "Please read this sentence.", hint: .chinese,
            context: "你好，这是中文上下文。") { sample in
            samples.append(sample)
            return [.english: 0.95, .french: 0.03]
        }
        #expect(language == .english)
        #expect(samples == ["Please read this sentence."])
    }

    @Test(arguments: ["chat", "Paris", "NASA", "Bonjour", "internationalization", "你好", "山田太郎", "123 !"])
    func ambiguousWordsUseTheirOwnContextRatherThanAConfidentIsolatedGuess(text: String) {
        var samples: [String] = []
        let context = "Nous parlons du chat dans cette phrase."
        let language = SpeechLanguageResolver.resolve(text: text, hint: .english, context: context) { sample in
            samples.append(sample)
            return [.french: 0.98, .english: 0.01]
        }
        #expect(language == .french)
        #expect(samples == [context])
    }

    @Test
    func lowConfidenceAndCloseScoresKeepTheHint() {
        for scores: [NLLanguage: Double] in [[.english: 0.54], [.english: 0.79, .french: 0.70],
                                            [.english: .nan, .french: .infinity], [.english: 1.2]] {
            #expect(SpeechLanguageResolver.resolve(text: "Some text with several words.", hint: .german,
                recognize: { _ in scores }) == .german)
        }
    }

    @Test
    func unsupportedConfidentLanguageIsNotRelabelledAsTheHint() {
        #expect(SpeechLanguageResolver.resolve(text: "Det här är en svensk mening.", hint: .english,
            recognize: { _ in [.swedish: 0.97, .english: 0.02] }) == nil)
    }

    @Test
    func providerUnsupportedLanguageStillResolvesBeforeCapabilityValidation() {
        #expect(SpeechLanguageResolver.resolve(text: "Dit is een Nederlandse zin.", hint: .english,
            recognize: { _ in [.dutch: 0.99] }) == .dutch)
        #expect(LocalSpeechLanguage.code(for: .dutch) == nil)
    }

    @Test
    func bothTextAndContextAreBoundedBeforeRecognition() {
        var lengths: [Int] = []
        let large = String(repeating: "long sentence with several words ", count: 1_000)
        let language = SpeechLanguageResolver.resolve(text: large, hint: .spanish, context: large) { sample in
            lengths.append(sample.count)
            return [:]
        }
        #expect(lengths == [600, 600])
        #expect(language == .spanish)
    }
}
