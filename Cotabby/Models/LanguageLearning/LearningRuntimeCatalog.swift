import Foundation

/// Task-specific recommendations share the existing download manager and GGUF directory. Keeping
/// this list separate prevents translation specialists from becoming recommended base completions.
nonisolated enum LearningRuntimeCatalog {
    /// These are application total budgets for prompt, source, references and output reserve;
    /// TranslateGemma's separate 2,048-token task-input cap is still enforced by its planner.
    /// Exact pinned filenames avoid inspecting files or inferring a family from aliases.
    static func defaultTranslationContextWindowTokens(for filename: String) -> Int? {
        guard let model = translationModels.first(where: {
            $0.filename.caseInsensitiveCompare(filename) == .orderedSame
        }) else { return nil }
        return switch model.filename.lowercased() {
        case "hy-mt2-1.8b-q4_k_m.gguf": 8_192
        case "translategemma-4b-it-q4_k_m.gguf": 4_096
        default: nil
        }
    }

    /// Shared storage must not make a downloaded translation specialist the fallback completion
    /// model. Keep custom imports eligible; only our task-specific catalog entries are excluded.
    static func isCompletionCandidate(filename: String) -> Bool {
        !(translationModels + analysisModels).contains { $0.filename.caseInsensitiveCompare(filename) == .orderedSame }
    }
    static let translationModels = [DownloadableRuntimeModel(
        filename: "Hy-MT2-1.8B-Q4_K_M.gguf",
        displayName: String(localized: "Hy-MT2 1.8B · Lightweight translation", table: "Learning",
            comment: "Display name for the recommended small Hy-MT2 translation model."),
        downloadURL: URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/Hy-MT2-1.8B-Q4_K_M.gguf?download=true")!,
        approximateSizeInGigabytes: 1.13, expectedSizeBytes: 1_133_080_448,
        sha256: "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699",
        recommendation: String(localized: "33 languages · Lightweight default for translating sentences after a pause.",
            table: "Learning", comment: "Recommendation shown for the small Hy-MT2 translation model.")), DownloadableRuntimeModel(
        filename: "Hy-MT2-7B-Q4_K_M.gguf",
        displayName: String(localized: "Hy-MT2 7B · Higher quality", table: "Learning",
            comment: "Display name for the larger Hy-MT2 translation model."),
        downloadURL: URL(string: "https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/ab8472660ac61fac25f1af43fac2599d52a8a775/Hy-MT2-7B-Q4_K_M.gguf?download=true")!,
        approximateSizeInGigabytes: 4.62, expectedSizeBytes: 4_624_648_896,
        sha256: "9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b",
        recommendation: String(localized: "33 languages · Larger translation model that requires more memory.",
            table: "Learning", comment: "Recommendation shown for the 7B Hy-MT2 translation model.")), DownloadableRuntimeModel(
        filename: "translategemma-4b-it-Q4_K_M.gguf",
        displayName: String(localized: "TranslateGemma 4B · Multilingual translation", table: "Learning",
            comment: "Display name for the multilingual TranslateGemma translation model."),
        downloadURL: URL(string: "https://huggingface.co/bullerwins/translategemma-4b-it-GGUF/resolve/7c938465a870d8624bcfa98a8e4a3510053c19a8/translategemma-4b-it-Q4_K_M.gguf?download=true")!,
        approximateSizeInGigabytes: 2.49, expectedSizeBytes: 2_489_909_312,
        sha256: "7f7357c14abd9da4eb200b38b05da502cd6e10d7e1d403fbc9f78c19f3209b72",
        recommendation: String(localized: """
        55 languages · Google's translation model, distributed as a text-only GGUF quantization by bullerwins.
        """,
            table: "Learning", comment: "Recommendation and provenance for the TranslateGemma GGUF model."))]
    /// The pinned text-model layer from Ollama's official registry is a standalone GGUF, not
    /// an Ollama service dependency. Candidate status makes no promise about teaching accuracy.
    /// Explanation borrows these existing general models, with task-neutral display names.
    /// This changes neither their downloads nor completion's task-specific catalog exclusion.
    static var explanationModels: [DownloadableRuntimeModel] {
        analysisModels.map { model in
            DownloadableRuntimeModel(filename: model.filename,
                displayName: model.filename.replacingOccurrences(of: ".gguf", with: ""), downloadURL: model.downloadURL,
                approximateSizeInGigabytes: model.approximateSizeInGigabytes, expectedSizeBytes: model.expectedSizeBytes,
                sha256: model.sha256, alternateFilenames: model.alternateFilenames)
        }
    }
    static let analysisModels = [DownloadableRuntimeModel(
        filename: "Gemma-4-E4B-Q4_K_M.gguf",
        displayName: String(localized: "Gemma 4 E4B · Chunk alignment", table: "Learning",
            comment: "Display name for a local model recommended for chunk alignment."),
        downloadURL: URL(string: "https://registry.ollama.ai/v2/library/gemma4/blobs/sha256:370c2879f17648d337b0ab4e208fdce348e24d1060064e93d7645daafd56d39c")!,
        approximateSizeInGigabytes: 5.49, expectedSizeBytes: 5_493_439_296,
        sha256: "370c2879f17648d337b0ab4e208fdce348e24d1060064e93d7645daafd56d39c"), DownloadableRuntimeModel(
        filename: "Qwen3.5-4B-Q4_K_M.gguf",
        displayName: String(localized: "Qwen3.5 4B · Chunk alignment", table: "Learning",
            comment: "Display name for a local model recommended for chunk alignment."),
        downloadURL: URL(string: "https://registry.ollama.ai/v2/library/qwen3.5/blobs/sha256:a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50")!,
        approximateSizeInGigabytes: 2.65, expectedSizeBytes: 2_648_593_216,
        sha256: "a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50")]
}
