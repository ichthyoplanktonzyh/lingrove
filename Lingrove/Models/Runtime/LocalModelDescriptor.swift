import Foundation

/// A model's product task is independent of its file identity and the runtime that loads it.
/// Catalog entries are immutable process-lifetime metadata; controllers borrow them for both
/// selection and presentation without constructing another runtime or moving model files.
nonisolated enum LocalModelTask: String, CaseIterable, Codable, Sendable {
    case completion, translation, explanation, speech

    init(_ role: LearningModelRole) {
        self = role == .translation ? .translation : .explanation
    }
}

nonisolated struct LocalModelDescriptor: Equatable, Sendable {
    let filename: String
    let task: LocalModelTask
    let name: String
    let quantization: String
    var isResource = false
}

/// This single alias/ownership table is shared by download rows, installed files and power
/// pickers. Names are product labels, never persistence keys or evidence of model compatibility.
nonisolated enum LocalModelCatalog {
    static let entries: [LocalModelDescriptor] = [
        .init(filename: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf", task: .completion, name: "Lingrove Nano", quantization: "Q6_K"),
        .init(filename: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf", task: .completion, name: "Lingrove Mini", quantization: "Q4_K_M"),
        .init(filename: "gemma-4-E2B.i1-Q6_K.gguf", task: .completion, name: "Lingrove Base", quantization: "Q6_K"),
        .init(filename: "gemma-4-E4B.i1-Q4_K_M.gguf", task: .completion, name: "Lingrove Pro", quantization: "Q4_K_M"),
        .init(filename: "Hy-MT2-1.8B-Q4_K_M.gguf", task: .translation, name: "Lingrove Translate Nano", quantization: "Q4_K_M"),
        .init(filename: "translategemma-4b-it-Q4_K_M.gguf", task: .translation, name: "Lingrove Translate Base", quantization: "Q4_K_M"),
        .init(filename: "Hy-MT2-7B-Q4_K_M.gguf", task: .translation, name: "Lingrove Translate Pro", quantization: "Q4_K_M"),
        .init(filename: "Qwen3.5-4B-Q4_K_M.gguf", task: .explanation, name: "Lingrove Explain Mini", quantization: "Q4_K_M"),
        .init(filename: "Gemma-4-E4B-Q4_K_M.gguf", task: .explanation, name: "Lingrove Explain Base", quantization: "Q4_K_M"),
        .init(filename: "Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M.gguf", task: .speech, name: "Lingrove Voice Mini", quantization: "Q4_K_M"),
        .init(filename: "Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf", task: .speech, name: "Lingrove Voice Base", quantization: "Q4_K_M"),
        .init(filename: "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf", task: .speech,
              name: "Lingrove Voice Base", quantization: "Q8_0", isResource: true),
        .init(filename: "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf", task: .speech,
              name: "Lingrove Voice Mini", quantization: "Q8_0", isResource: true),
        .init(filename: "Qwen3-TTS-12Hz-0.6B-Base.mmproj-Q8_0.gguf", task: .speech,
              name: "Lingrove Voice Mini", quantization: "Q8_0", isResource: true)
    ]

    static func descriptor(for filename: String) -> LocalModelDescriptor? {
        entries.first { $0.filename.caseInsensitiveCompare(filename) == .orderedSame }
    }

    static func displayName(for filename: String) -> String {
        guard let entry = descriptor(for: filename) else { return filename }
        let name = Bundle.main.localizedString(forKey: entry.name, value: entry.name, table: "Learning")
        return entry.isResource
            ? name + " · " + String(localized: "Audio decoder", table: "Learning") : name
    }

    static func downloadMetadata(for filename: String) -> DownloadableRuntimeModel? {
        let models = RuntimeModelCatalog.downloadableModels + LearningRuntimeCatalog.translationModels
            + LearningRuntimeCatalog.explanationModels + [SpeechModelCatalog.model, SpeechModelCatalog.decoder]
        return models.first { $0.allKnownFilenames.contains { $0.caseInsensitiveCompare(filename) == .orderedSame } }
    }
}
