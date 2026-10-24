import Testing
@testable import Lingrove

/// Voice policy is locale-sensitive: saved ids may disappear, but fallback stays within the
/// requested language and gives an explicitly selected compatible voice priority.
@Suite
struct SpeechVoicePolicyTests {
    private static let voices = [
        SpeechVoice(id: "en-US", name: "en-US", language: "en-US", quality: .premium),
        SpeechVoice(id: "es-ES-standard", name: "es-ES-standard", language: "es-ES", quality: .standard),
        SpeechVoice(id: "es-MX-enhanced", name: "es-MX-enhanced", language: "es-MX", quality: .enhanced),
        SpeechVoice(id: "es-ES-premium", name: "es-ES-premium", language: "es-ES", quality: .premium),
        SpeechVoice(id: "es-novelty", name: "Novelty", language: "es-ES", quality: .premium, isNovelty: true),
        SpeechVoice(id: "es-system", name: "System default", language: "es-MX", quality: .standard,
                    isSystemPreferred: true),
        SpeechVoice(id: "zh-hans", name: "zh-hans", language: "zh-Hans", quality: .standard),
        SpeechVoice(id: "zh-cn-premium", name: "zh-cn-premium", language: "zh-CN", quality: .premium),
        SpeechVoice(id: "zh-hant", name: "zh-hant", language: "zh-Hant", quality: .enhanced),
        SpeechVoice(id: "zh-tw-premium", name: "zh-tw-premium", language: "zh-TW", quality: .premium)
    ]

    @Test
    func unavailableOrWrongLanguagePreferenceFallsBackOnlyWithinRequestedLanguage() {
        let missing = SpeechVoicePolicy.select(from: Self.voices, language: .spanish, preferredVoiceID: "removed")
        let wrongLanguage = SpeechVoicePolicy.select(from: Self.voices, language: .spanish, preferredVoiceID: "en-US")

        #expect(missing?.id == "es-system")
        #expect(wrongLanguage?.id == "es-system")
        #expect(SpeechVoicePolicy.select(from: Self.voices, language: .hindi, preferredVoiceID: "en-US") == nil)
    }

    @Test
    func validExplicitVoiceWinsOverQualityRanking() {
        let selected = SpeechVoicePolicy.select(
            from: Self.voices, language: .spanish, preferredVoiceID: "es-ES-standard"
        )

        #expect(selected?.id == "es-ES-standard")
    }

    @Test
    func automaticChoicePrefersSystemDefaultAndSkipsNoveltyButExplicitChoiceIsHonored() {
        let automatic = SpeechVoicePolicy.select(from: Self.voices, language: .spanish, preferredVoiceID: nil)
        let explicitNovelty = SpeechVoicePolicy.select(
            from: Self.voices, language: .spanish, preferredVoiceID: "es-novelty"
        )

        #expect(automatic?.id == "es-system")
        #expect(explicitNovelty?.id == "es-novelty")
    }

    @Test
    func exactLanguageTagAndQualityDetermineStableFallbackOrder() {
        let spanish = SpeechVoicePolicy.voices(
            Self.voices.filter { !$0.isSystemPreferred && !$0.isNovelty }, for: .spanish
        )
        let simplified = SpeechVoicePolicy.voices(Self.voices, for: .chinese)
        let traditional = SpeechVoicePolicy.voices(Self.voices, for: .traditionalChinese)

        #expect(spanish.first?.id == "es-ES-premium")
        #expect(simplified.map(\.id) == ["zh-hans", "zh-cn-premium"])
        #expect(traditional.map(\.id) == ["zh-hant", "zh-tw-premium"])
        #expect(SpeechVoicePolicy.languageMatch("zh-TW", for: .chinese) == nil)
        #expect(SpeechVoicePolicy.languageMatch("zh-CN", for: .traditionalChinese) == nil)
    }
}
