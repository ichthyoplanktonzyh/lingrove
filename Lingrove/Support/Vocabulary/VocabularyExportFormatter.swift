import Foundation

/// All formats serialize the same portable projection. This value-only boundary is independent
/// of SwiftUI and IO, so delimiter/Unicode behavior and omitted fields can be verified directly.
nonisolated enum VocabularyExportFormatter {
    typealias Document = VocabularyExportDocument

    static func render(_ document: Document, configuration: VocabularyExportConfiguration) throws -> Data {
        switch configuration.format {
        case .json:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(document)
        case .csv: return try csv(document, options: configuration)
        case .text: return try text(document, list: configuration.isExpressionList)
        }
    }

    static func preview(_ data: Data, format: VocabularyExportFormat) -> String {
        let body = format == .csv && data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        var prefix = Data(body.prefix(16_000))
        // A byte budget must stop at a UTF-8 boundary rather than replacing half of a CJK glyph.
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return (String(data: prefix, encoding: .utf8) ?? "") + (body.count > prefix.count ? "\n…" : "")
    }

    /// Quote every CSV cell, including embedded newlines. Spreadsheet formula prefixes are
    /// escaped at this boundary while JSON and TXT retain the original learning text verbatim.
    static func csvCell(_ text: String, spreadsheetCompatibility: Bool = true) -> String {
        let significant = text.drop(while: { $0.isWhitespace || $0.isNewline })
        let value = spreadsheetCompatibility && significant.first.map { "=+-@".contains($0) } == true ? "'" + text : text
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func append(_ text: String, to data: inout Data) throws {
        let bytes = Data(text.utf8)
        guard bytes.count <= VocabularyExportPolicy.maximumDataBytes - data.count else { throw VocabularyExportError.tooLarge }
        data.append(bytes)
    }

    private static func text(_ document: Document, list: Bool) throws -> Data {
        var data = Data(), seen = Set<String>()
        for entry in document.entries {
            try Task.checkCancellation()
            if list {
                let expression = VocabularyPolicy.normalized(entry.expression)
                if seen.insert(entry.language.rawValue + "\0" + expression).inserted { try append(expression + "\n", to: &data) }
                continue
            }
            try append(entry.expression + " [" + entry.language.rawValue + "]\n", to: &data)
            if entry.dictionaryForm != entry.expression {
                try append(String(localized: "Dictionary form", table: "Vocabulary") + ": " + entry.dictionaryForm + "\n", to: &data)
            }
            for (index, sense) in entry.senses.enumerated() {
                try Task.checkCancellation()
                let heading = String(localized: "Sense", table: "Vocabulary") + " " + String(index + 1)
                try append("\n" + heading + ": " + languageText(sense.meaning ?? "", sense.meaningLanguage) + "\n", to: &data)
                if let meanings = sense.otherMeanings { try append(meaningsText(meanings) + (meanings.isEmpty ? "" : "\n"), to: &data) }
                if let note = sense.note, !note.isEmpty {
                    try append(String(localized: "Notes", table: "Vocabulary") + ": " + note + "\n", to: &data)
                }
                if let tags = sense.tags, !tags.isEmpty {
                    try append(String(localized: "Tags", table: "Vocabulary") + ": " + tags.joined(separator: "; ") + "\n", to: &data)
                }
                try append(blockText(sense.content ?? []) + explanationText(sense.explanations ?? []), to: &data)
                for usage in sense.examples ?? [] {
                    try Task.checkCancellation()
                    try appendUsage(usage, to: &data)
                }
            }
            try append("\n────────────────────\n\n", to: &data)
        }
        return data
    }

    private static func appendUsage(_ usage: Document.Usage, to data: inout Data) throws {
        try append("\n" + String(localized: "Example sentence", table: "Vocabulary") + ": " + usage.text + "\n", to: &data)
        if !usage.translation.isEmpty {
            let label = String(localized: "Example translation", table: "Vocabulary")
            try append(label + ": " + languageText(usage.translation, usage.translationLanguage) + "\n", to: &data)
        }
        try append(meaningsText(usage.otherTranslations) + (usage.otherTranslations.isEmpty ? "" : "\n"), to: &data)
        if let meaning = usage.meaning, !meaning.isEmpty {
            let label = String(localized: "Contextual meaning", table: "Vocabulary")
            try append(label + ": " + languageText(meaning, usage.meaningLanguage) + "\n", to: &data)
        }
        try append(explanationText(usage.explanations ?? []), to: &data)
    }

    private static func csv(_ document: Document, options: VocabularyExportConfiguration) throws -> Data {
        var data = options.spreadsheetCompatibility ? Data([0xEF, 0xBB, 0xBF]) : Data()
        let cell = { (text: String) in csvCell(text, spreadsheetCompatibility: options.spreadsheetCompatibility) }
        try append(csvColumns(options).map(cell).joined(separator: ",") + "\r\n", to: &data)
        for entry in document.entries {
            for sense in entry.senses {
                let examples = options.examples ? sense.examples ?? [] : []
                let usages: [Document.Usage?] = examples.isEmpty ? [nil] : examples.map(Optional.some)
                for usage in usages {
                    try Task.checkCancellation()
                    let values = csvValues(entry: entry, sense: sense, usage: usage, options: options)
                    try append(values.map(cell).joined(separator: ",") + "\r\n", to: &data)
                }
            }
        }
        return data
    }

    private static func csvColumns(_ options: VocabularyExportConfiguration) -> [String] {
        var columns = ["entry_id", "expression", "dictionary_form", "language", "type", "sense_id", "saved_at"]
        if options.meanings { columns += ["meaning", "meaning_language", "other_meanings"] }
        if options.examples {
            columns += ["usage_id", "usage_saved_at", "example", "translation", "translation_language", "other_translations"]
            if options.meanings { columns += ["contextual_meaning", "contextual_meaning_language"] }
        }
        if options.notes { columns += ["notes", "tags"] }
        if options.explanation { columns += ["sense_explanations", "usage_explanations"] }
        if options.content { columns += ["supplemental_text", "images", "image_captions"] }
        return columns
    }

    private static func csvValues(
        entry: Document.Entry, sense: Document.Sense, usage: Document.Usage?, options: VocabularyExportConfiguration
    ) -> [String] {
        var values = [entry.id.uuidString, entry.expression, entry.dictionaryForm, entry.language.rawValue, entry.kind.rawValue,
            sense.id.uuidString, sense.createdAt.formatted(.iso8601)]
        if options.meanings { values += [sense.meaning ?? "", sense.meaningLanguage?.rawValue ?? "",
            meaningsText(sense.otherMeanings ?? [])] }
        if options.examples {
            values += [usage?.id.uuidString ?? "", usage?.createdAt.formatted(.iso8601) ?? "", usage?.text ?? "",
                usage?.translation ?? "", usage?.translationLanguage?.rawValue ?? "", meaningsText(usage?.otherTranslations ?? [])]
            if options.meanings { values += [usage?.meaning ?? "", usage?.meaningLanguage?.rawValue ?? ""] }
        }
        if options.notes { values += [sense.note ?? "", (sense.tags ?? []).joined(separator: "; ")] }
        if options.explanation {
            values += [explanationText(sense.explanations ?? []), explanationText(usage?.explanations ?? [])]
        }
        if options.content {
            let blocks = sense.content ?? []
            values += [blocks.compactMap { $0.text?.text }.joined(separator: "\n\n"),
                blocks.compactMap(\.filename).joined(separator: "\n"), blocks.compactMap(\.caption).joined(separator: "\n")]
        }
        return values
    }

    private static func languageText(_ text: String, _ language: LearningLanguage?) -> String {
        guard !text.isEmpty else { return "" }
        return (language.map { "[" + $0.rawValue + "] " } ?? "") + text
    }
    private static func meaningsText(_ meanings: [VocabularyMeaning]) -> String {
        meanings.map { ($0.language.map { "[" + $0.rawValue + "] " } ?? "") + $0.text }.joined(separator: "\n")
    }
    private static func explanationText(_ records: [Document.Explanation]) -> String {
        records.map { "[" + $0.language.rawValue + "] " + $0.meaning + "\n" + $0.detail + "\n" }.joined(separator: "\n")
    }
    private static func blockText(_ blocks: [Document.Block]) -> String {
        blocks.map { block in
            if let text = block.text { return text.text + "\n" }
            return String(localized: "Image", table: "Vocabulary") + ": " + (block.filename ?? "") +
                (block.caption.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "") + "\n"
        }.joined()
    }
}
