import Foundation

/// Bounded, value-only CSV/TXT decoding. Quoted commas, escaped quotes and embedded newlines
/// remain text; no spreadsheet cells, formulas, paths or model instructions are executed.
nonisolated enum VocabularyWordListPolicy {
    static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumRows = 10_000
    private static let maximumColumns = 64

    static func decode(_ data: Data, fileExtension suffix: String) throws -> VocabularyWordList {
        guard data.count <= maximumBytes else { throw VocabularyWordListError.tooLarge }
        guard ["csv", "txt"].contains(suffix.lowercased()) else { throw VocabularyWordListError.unsupportedFile }
        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
        guard var text = String(data: data, encoding: encoding), !text.contains("\0") else { throw VocabularyWordListError.encoding }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows: [VocabularyWordList.Row]
        if suffix.lowercased() == "csv" { rows = try csv(text) } else {
            rows = try textRows(text)
        }
        guard !rows.isEmpty else { throw VocabularyWordListError.empty }
        return .init(format: suffix.lowercased() == "csv" ? .csv : .text, rows: rows)
    }

    static func configuration(for table: VocabularyWordList, language: LearningLanguage) -> VocabularyWordListConfiguration {
        var result = VocabularyWordListConfiguration(language: language)
        guard table.format == .csv, let first = table.rows.first else { return result }
        let aliases: [VocabularyImportField: Set<String>] = [
            .expression: ["expression", "word", "term", "front", "词条", "单词", "词语", "表达"],
            .meaning: ["meaning", "definition", "translation", "back", "释义", "含义", "翻译"],
            .dictionaryForm: ["dictionaryform", "lemma", "原形", "词典形式"],
            .language: ["language", "lang", "语言"],
            .kind: ["type", "kind", "类型"],
            .meaningLanguage: ["meaninglanguage", "释义语言"],
            .note: ["notes", "note", "备注", "笔记"],
            .tags: ["tags", "tag", "标签"]
        ]
        let names = first.cells.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        var mapped: [VocabularyImportField: Int] = [:]
        for field in VocabularyImportField.allCases {
            if let index = names.firstIndex(where: { aliases[field, default: []].contains($0) }) { mapped[field] = index }
        }
        result.hasHeader = mapped[.expression] != nil
        if result.hasHeader { result.columns = mapped } else if table.columnCount > 1 { result.columns[.meaning] = 1 }
        return result
    }

    static func inputs(_ table: VocabularyWordList, configuration: VocabularyWordListConfiguration) throws -> [VocabularyEntryInput] {
        guard let expression = configuration.columns[.expression], expression >= 0, expression < table.columnCount,
              configuration.columns.values.allSatisfy({ $0 >= 0 && $0 < table.columnCount }) else {
            throw VocabularyWordListError.mapping
        }
        let rows = table.rows.dropFirst(configuration.hasHeader ? 1 : 0)
        guard !rows.isEmpty else { throw VocabularyWordListError.empty }
        guard rows.count <= maximumRows else { throw VocabularyWordListError.tooLarge }
        return try rows.map { row in
            try Task.checkCancellation()
            func cell(_ field: VocabularyImportField) -> String {
                guard let index = configuration.columns[field], index < row.cells.count else { return "" }
                return row.cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !cell(.expression).isEmpty else { throw VocabularyWordListError.missingExpression(row.line) }
            let language = try Self.language(cell(.language), fallback: configuration.language, line: row.line)
            let meaningLanguage = try optionalLanguage(cell(.meaningLanguage), fallback: configuration.meaningLanguage, line: row.line)
            let kind: VocabularyEntry.Kind
            if cell(.kind).isEmpty { kind = configuration.kind
            } else if let value = VocabularyEntry.Kind(rawValue: cell(.kind).lowercased()) { kind = value
            } else { throw VocabularyWordListError.kind(row.line) }
            let tags = cell(.tags).components(separatedBy: CharacterSet(charactersIn: ";；,，"))
            return try VocabularyEntryInputPolicy.validated(.init(expression: cell(.expression),
                dictionaryForm: cell(.dictionaryForm), language: language, kind: kind, meaning: cell(.meaning),
                meaningLanguage: meaningLanguage, note: cell(.note), tags: tags))
        }
    }

    private static func textRows(_ text: String) throws -> [VocabularyWordList.Row] {
        var rows: [VocabularyWordList.Row] = [], lineNumber = 0
        var oversized = false
        text.enumerateLines { line, stop in
            lineNumber += 1
            if Task.isCancelled { stop = true; return }
            let expression = line.trimmingCharacters(in: .whitespaces)
            guard !expression.isEmpty else { return }
            guard rows.count < maximumRows else { oversized = true; stop = true; return }
            rows.append(.init(line: lineNumber, cells: [expression]))
        }
        try Task.checkCancellation()
        if oversized { throw VocabularyWordListError.tooLarge }
        return rows
    }

    private static func language(_ text: String, fallback: LearningLanguage, line: Int) throws -> LearningLanguage {
        try optionalLanguage(text, fallback: fallback, line: line) ?? fallback
    }

    private static func optionalLanguage(_ text: String, fallback: LearningLanguage?, line: Int) throws -> LearningLanguage? {
        guard !text.isEmpty else { return fallback }
        guard let language = LearningLanguage.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(text) == .orderedSame }) else {
            throw VocabularyWordListError.language(line)
        }
        return language
    }

    private enum CSVState { case plain, quoted, closed }

    private static func csv(_ text: String) throws -> [VocabularyWordList.Row] {
        var reader = CSVReader(bytes: Array(text.utf8))
        return try reader.read()
    }

    /// One transient reader owns one cursor and record buffer. Keeping quoted and unquoted
    /// transitions separate makes CSV state explicit without mixing it with column interpretation.
    private struct CSVReader {
        let bytes: [UInt8]
        var state = CSVState.plain
        var index = 0, line = 1, startLine = 1
        var field: [UInt8] = []
        var cells: [String] = []
        var rows: [VocabularyWordList.Row] = []

        mutating func read() throws -> [VocabularyWordList.Row] {
            while index < bytes.count {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                if state == .quoted { consumeQuoted(bytes[index]) } else { try consumePlain(bytes[index]) }
                guard field.count <= 262_144 else { throw VocabularyWordListError.tooLarge }
                index += 1
            }
            guard state != .quoted else { throw VocabularyWordListError.malformedCSV(startLine) }
            if !field.isEmpty || !cells.isEmpty || state == .closed { try finishRow() }
            return rows
        }

        private mutating func consumeQuoted(_ byte: UInt8) {
            if byte == 34 {
                if index + 1 < bytes.count, bytes[index + 1] == 34 { field.append(34); index += 1
                } else { state = .closed }
            } else {
                field.append(byte)
                if byte == 10 || byte == 13 && (index + 1 == bytes.count || bytes[index + 1] != 10) { line += 1 }
            }
        }

        private mutating func consumePlain(_ byte: UInt8) throws {
            switch byte {
            case 44: try finishCell()
            case 10, 13:
                try finishRow()
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                line += 1; startLine = line
            case 34:
                guard state == .plain, field.isEmpty else { throw VocabularyWordListError.malformedCSV(line) }
                state = .quoted
            default:
                if state == .closed {
                    guard byte == 32 || byte == 9 else { throw VocabularyWordListError.malformedCSV(line) }
                } else { field.append(byte) }
            }
        }

        private mutating func finishCell() throws {
            guard cells.count < maximumColumns, field.count <= 262_144,
                  let value = String(bytes: field, encoding: .utf8) else { throw VocabularyWordListError.tooLarge }
            cells.append(value); field.removeAll(keepingCapacity: true); state = .plain
        }

        private mutating func finishRow() throws {
            try finishCell()
            if cells.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                guard rows.count <= maximumRows else { throw VocabularyWordListError.tooLarge }
                rows.append(.init(line: startLine, cells: cells))
            }
            cells.removeAll(keepingCapacity: true)
        }
    }
}
