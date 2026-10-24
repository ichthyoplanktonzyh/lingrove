import Foundation

/// Exact companion metadata for the two tested Qwen packages, shared by selection, validation
/// and display. This stateless policy never loads weights or guesses compatibility for imports;
/// the controller checks file availability and settings retain explicit custom decoder choices.
nonisolated enum SpeechModelPairingPolicy {
    /// Immutable metadata lives with the policy rather than creating model/runtime services.
    /// Grouping these values prevents display and validation from choosing different companions.
    private struct Package: Sendable {
        let model: String
        let decoders: [String]
    }

    private static let packages: [Package] = [
        .init(model: "Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf",
              decoders: ["mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"]),
        .init(model: "Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M.gguf",
              decoders: ["mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf", "Qwen3-TTS-12Hz-0.6B-Base.mmproj-Q8_0.gguf"])
    ]

    static func decoderFilenames(for modelFilename: String) -> [String] {
        packages.first { $0.model == modelFilename }?.decoders ?? []
    }

    static func isKnownDecoder(_ filename: String) -> Bool {
        packages.contains { $0.decoders.contains(filename) }
    }

    /// Reject a known cross-package pairing without forbidding a user's renamed/requantized
    /// custom decoder. Unknown files still pass through the runtime's native compatibility checks.
    static func isKnownMismatch(model: String, decoder: String) -> Bool {
        let expected = decoderFilenames(for: model)
        return !expected.isEmpty && isKnownDecoder(decoder) && !expected.contains(decoder)
    }

    static func displayName(for filename: String) -> String? {
        LocalModelCatalog.descriptor(for: filename).map { _ in LocalModelCatalog.displayName(for: filename) }
    }
}
