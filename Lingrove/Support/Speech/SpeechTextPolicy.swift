import Foundation

/// Converts one recognized learning unit into a bounded spoken phrase. This lives beside the
/// learning-unit model rather than in SwiftUI so both preview and detail speakers read the same
/// text, and malformed model output cannot send unbounded strings into the audio subsystem.
nonisolated enum SpeechTextPolicy {
    static let maximumLength = 1_000

    /// Words and expressions use their real displayed surface. Pattern units paint gaps as visual
    /// ellipses, so their complete token list (including pronoun slots) is spoken in source order.
    static func spokenText(for unit: LearningUnit) -> String? {
        let candidate: String
        switch unit.kind {
        case .word, .expression:
            candidate = unit.surface
        case .pattern:
            guard !unit.words.isEmpty,
                  unit.words.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return nil
            }
            candidate = unit.words.map(\.text).joined(separator: " ")
        }
        return sanitizedText(candidate)
    }

    /// Also protects direct service callers that do not originate from a LearningUnit.
    static func sanitizedText(_ text: String) -> String? {
        guard text.utf8.count <= 8_192 else { return nil }
        let safeScalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(safeScalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}

/// Qwen's fixed language inventory is independent of the interface locale and system voice list.
nonisolated enum LocalSpeechLanguage {
    private static let codes: [LearningLanguage: String] = [
        .english: "en", .chinese: "zh", .traditionalChinese: "zh", .japanese: "ja", .korean: "ko",
        .german: "de", .french: "fr", .russian: "ru", .portuguese: "pt", .spanish: "es", .italian: "it"
    ]

    static func code(for language: LearningLanguage) -> String? { codes[language] }

}

/// Pure selection policy. A saved id is honored only if it still belongs to the requested
/// language; an unavailable or mismatched id falls back within that language, never to English.
nonisolated enum SpeechVoicePolicy {
    enum LanguageMatch: Int, Equatable, Sendable { case exact = 0, sameLanguage = 1 }

    static func voices(_ catalog: [SpeechVoice], for language: LearningLanguage) -> [SpeechVoice] {
        catalog
            .compactMap { voice -> (SpeechVoice, LanguageMatch)? in
                guard let match = languageMatch(voice.language, for: language) else { return nil }
                return (voice, match)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1.rawValue < rhs.1.rawValue }
                if lhs.0.isNovelty != rhs.0.isNovelty { return !lhs.0.isNovelty }
                if lhs.0.isSystemPreferred != rhs.0.isSystemPreferred { return lhs.0.isSystemPreferred }
                if lhs.0.quality != rhs.0.quality { return lhs.0.quality > rhs.0.quality }
                return lhs.0.id.localizedStandardCompare(rhs.0.id) == .orderedAscending
            }
            .map(\.0)
    }

    static func select(
        from catalog: [SpeechVoice], language: LearningLanguage, preferredVoiceID: String?
    ) -> SpeechVoice? {
        let compatible = voices(catalog, for: language)
        if let preferredVoiceID, let preferred = compatible.first(where: { $0.id == preferredVoiceID }) {
            return preferred
        }
        return compatible.first(where: { !$0.isNovelty })
    }

    static func languageMatch(_ voiceIdentifier: String, for language: LearningLanguage) -> LanguageMatch? {
        let voiceTag = normalizedTag(voiceIdentifier)
        let languageTag = normalizedTag(language.rawValue)
        if voiceTag == languageTag { return .exact }

        let voiceParts = voiceTag.split(separator: "-").map(String.init)
        let languageParts = languageTag.split(separator: "-").map(String.init)
        guard voiceParts.first == languageParts.first else { return nil }

        // Chinese voice inventories commonly identify script by either an explicit Hans/Hant
        // subtag or a region. Bare zh is ambiguous, so it cannot silently cross script variants.
        if languageParts.first == "zh" {
            guard let requestedScript = languageParts.dropFirst().first(where: { $0 == "hans" || $0 == "hant" }),
                  let voiceScript = chineseScript(in: voiceParts), voiceScript == requestedScript else { return nil }
        }
        return .sameLanguage
    }

    private static func normalizedTag(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func chineseScript(in components: [String]) -> String? {
        if let script = components.dropFirst().first(where: { $0 == "hans" || $0 == "hant" }) { return script }
        guard let region = components.dropFirst().first(where: { $0.count == 2 })?.uppercased() else { return nil }
        switch region {
        case "CN", "SG": return "hans"
        case "TW", "HK", "MO": return "hant"
        default: return nil
        }
    }
}
