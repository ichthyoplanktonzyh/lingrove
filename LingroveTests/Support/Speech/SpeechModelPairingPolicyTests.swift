import Testing
@testable import Lingrove

/// These filenames reproduce the installed 0.6B/1.7B packages, including the upstream decoder
/// alias. Unknown imports remain explicit rather than relying on a guessed filename pattern.
@Suite struct SpeechModelPairingPolicyTests {
    @Test func identifiesTheCrossSizePairThatFailedInSettings() {
        let model = "Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M.gguf"
        #expect(SpeechModelPairingPolicy.isKnownMismatch(model: model,
            decoder: "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"))
        #expect(!SpeechModelPairingPolicy.isKnownMismatch(model: model,
            decoder: "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"))
        #expect(!SpeechModelPairingPolicy.isKnownMismatch(model: model,
            decoder: "Qwen3-TTS-12Hz-0.6B-Base.mmproj-Q8_0.gguf"))
    }

    @Test func unknownImportsKeepManualCompatibilityAndLabelsShowTheSize() {
        #expect(!SpeechModelPairingPolicy.isKnownMismatch(model: "custom.gguf", decoder: "decoder.gguf"))
        #expect(SpeechModelPairingPolicy.decoderFilenames(for: "custom.gguf").isEmpty)
        #expect(SpeechModelPairingPolicy.displayName(for: "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf")?.contains("0.6B") == true)
        #expect(SpeechModelPairingPolicy.displayName(for: "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf")?.contains("1.7B") == true)
    }
}
