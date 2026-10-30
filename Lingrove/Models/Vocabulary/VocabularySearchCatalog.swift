import Foundation

/// App-managed embedding weights are an optional resource, isolated from generative model
/// discovery. The pinned identity also versions derived vectors, which can always be rebuilt.
nonisolated enum VocabularySearchCatalog {
    static let identity = "qwen3-embedding-0.6b-q8_0-370f27d-material-v1"
    static let dimensions = 1_024
    static var directoryURL: URL {
        BundledRuntimeLocator.userRuntimeDirectoryURL().deletingLastPathComponent()
            .appendingPathComponent("SearchModels", isDirectory: true)
    }
    static var cacheURL: URL { directoryURL.appendingPathComponent("sense-vectors.json") }
    static let model = DownloadableRuntimeModel(
        filename: "Qwen3-Embedding-0.6B-Q8_0.gguf",
        displayName: "Qwen3 Embedding 0.6B · Q8_0",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf?download=true")!,
        approximateSizeInGigabytes: 0.639, expectedSizeBytes: 639_150_592,
        sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439")
}
