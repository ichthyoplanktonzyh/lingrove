import Foundation

/// A translation destination's durable expression preference. Natural preserves the original
/// adapter prompt byte-for-byte; other registers affect phrasing only, never the target range.
/// The settings model owns persistence; a request retains a sanitized immutable copy.
nonisolated struct LearningTranslationStyle: Codable, Equatable, Hashable, Sendable {
    enum Register: String, CaseIterable, Codable, Identifiable, Sendable {
        case natural, formal, conversational, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .natural: String(localized: "Natural and faithful", table: "Learning")
            case .formal: String(localized: "Formal writing", table: "Learning")
            case .conversational: String(localized: "Everyday conversation", table: "Learning")
            case .custom: String(localized: "Custom", table: "Learning")
            }
        }
    }
    var register: Register = .natural
    var customInstruction = ""

    var normalized: Self {
        // The byte cap may split the final UTF-8 scalar; decoding deliberately replaces it.
        // swiftlint:disable:next optional_data_string_conversion
        .init(register: register, customInstruction: String(String(decoding: customInstruction.utf8.prefix(4_000),
            as: UTF8.self).prefix(1_000)))
    }

    var effective: Self { register == .custom ? normalized : .init(register: register) }

    /// This is a user-authored preference channel, separate from both literal source and draft
    /// reference. Fixed invariants follow it in the prompt so style never broadens translation.
    var instruction: String? {
        switch register {
        case .natural: nil
        case .formal: "Use a formal written register suitable for documents."
        case .conversational: "Use natural everyday conversational phrasing."
        case .custom:
            normalized.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : normalized.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// One role's provider/model profile. Keeping expression and sampler preferences together makes
/// switching models atomic while preserving independent translation/analysis destinations.
nonisolated struct LearningGenerationProfile: Codable, Equatable, Hashable, Sendable {
    var style = LearningTranslationStyle()
    var sampling = ModelSamplingOverrides()
}
