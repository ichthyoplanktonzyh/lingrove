import Foundation

/// Source metadata describes the language of the headword separately from its definitions.
/// Nil is explicitly unknown (or multilingual for a curated website), never a guessed language.
/// Settings own these values; routing uses them without re-detecting ambiguous short words.
nonisolated struct DictionaryLanguagePair: Codable, Equatable, Sendable {
    var entry: LearningLanguage?
    var definition: LearningLanguage?
    var multilingual: Bool?

    func supports(_ language: LearningLanguage?) -> Bool {
        guard let entry, let language else { return true }
        return Self.family(entry) == Self.family(language)
    }

    var label: String {
        let head = entry?.label ?? (multilingual == true ? String(localized: "Multilingual", table: "Learning")
            : String(localized: "Unspecified", table: "Learning"))
        let gloss = definition?.label ?? String(localized: "Unspecified", table: "Learning")
        return head + " → " + gloss
    }

    static func family(_ language: LearningLanguage) -> String {
        language == .chinese || language == .traditionalChinese ? "zh" : language.rawValue
    }

    static func definitionLanguage(for localeIdentifier: String) -> LearningLanguage {
        let code = localeIdentifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if code.hasPrefix("zh") {
            return code.contains("hant") || ["tw", "hk", "mo"].contains(code.split(separator: "-").last.map(String.init) ?? "")
                ? .traditionalChinese : .chinese
        }
        return LearningLanguage(rawValue: String(code.prefix(2))) ?? .english
    }
}

/// Preconfigured browser destinations contain no dictionary data or background networking.
/// Stable UUIDs make repeated Add idempotent while still allowing the user to edit each copy.
nonisolated enum DictionaryWebsiteCatalog {
    static let websites: [DictionaryWebsite] = [
        site(1, "Cambridge · English–中文", "https://dictionary.cambridge.org/dictionary/english-chinese-simplified/{query}",
             .english, .chinese),
        site(2, "Cambridge · English–繁體中文", "https://dictionary.cambridge.org/dictionary/english-chinese-traditional/{query}",
             .english, .traditionalChinese),
        site(3, "Cambridge · English", "https://dictionary.cambridge.org/dictionary/english/{query}", .english, .english),
        site(4, "Oxford Learner’s Dictionaries", "https://www.oxfordlearnersdictionaries.com/definition/english/{query}",
             .english, .english),
        site(5, "Wiktionary · English", "https://en.wiktionary.org/wiki/{query}", nil, .english),
        site(6, "維基詞典 · 中文", "https://zh.wiktionary.org/wiki/{query}", nil, .chinese),
        site(7, "汉典", "https://www.zdic.net/hans/{query}", .chinese, .chinese),
        site(8, "Diccionario de la lengua española", "https://dle.rae.es/{query}", .spanish, .spanish)
    ]

    private static func site(_ number: Int, _ name: String, _ template: String,
                             _ entry: LearningLanguage?, _ definition: LearningLanguage) -> DictionaryWebsite {
        // The literal prefix plus two digits is a valid UUID for all eight curated entries.
        guard let id = UUID(uuidString: "81B75A7A-BC16-4BE4-9307-0000000000" + String(format: "%02d", number)) else {
            preconditionFailure("Curated website identity must be a UUID")
        }
        return .init(id: id, name: name, template: template,
                     languages: .init(entry: entry, definition: definition, multilingual: entry == nil))
    }
}
