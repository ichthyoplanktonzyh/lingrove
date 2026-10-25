import Foundation

/// One tested model package consists of a talker and its audio decoder. Reusing the existing
/// download manager preserves pause/resume, progress, exact-size and SHA-256 verification.
/// Speech weights live beside the completion folder, so they never appear as completion models.
enum SpeechModelCatalog {
    static var directoryURL: URL {
        BundledRuntimeLocator.userRuntimeDirectoryURL().deletingLastPathComponent()
            .appendingPathComponent("SpeechModels", isDirectory: true)
    }

    private static let base = "https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/"
        + "ca27d74bc954b73dadab5b71ca265d87fc861a7c/"

    static let model = asset(
        name: "Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf",
        size: 1_035_965_280, hash: "8d18c94acb2addd042f97da63c98be144eafa76d0d9495177eab65130cf85129")
    static let decoder = asset(
        name: "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf",
        size: 446_422_912, hash: "6fd65188839bcd6ecc91b277ad471e22a0edfada4699a0fe82f1165c18cfcce2")

    static func displayName(for filename: String) -> String {
        SpeechModelPairingPolicy.displayName(for: filename)
            ?? [model, decoder].first(where: { $0.filename == filename })?.displayName ?? filename
    }

    private static func asset(name: String, size: Int64, hash: String) -> DownloadableRuntimeModel {
        // Catalog constants form a fixed HTTPS URL, never a user-configurable transmission target.
        guard let url = URL(string: base + name + "?download=true") else { preconditionFailure("Invalid speech catalog URL") }
        return .init(filename: name, displayName: LocalModelCatalog.displayName(for: name), downloadURL: url,
            approximateSizeInGigabytes: Double(size) / 1_000_000_000, expectedSizeBytes: size, sha256: hash)
    }
}
