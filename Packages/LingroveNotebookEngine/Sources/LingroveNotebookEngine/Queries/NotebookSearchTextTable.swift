import Foundation

/// One immutable table belongs to a corpus-fenced search material. Senses and semantic joins
/// retain integer references, so repeated evidence/labels share both their text and query work.
/// This is disposable retrieval state, never persistence, an embedding index or writer proof.
nonisolated struct NotebookSearchTextTable: Sendable {
    struct Field: Sendable {
        let text: String
        let ascii: [UInt8]?
        init(_ text: String) {
            self.text = text
            ascii = Self.foldASCII(text)
        }
        static func foldASCII(_ text: String) -> [UInt8]? {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            for byte in text.utf8 {
                guard byte < 128 else { return nil }
                bytes.append((65...90).contains(byte) ? byte + 32 : byte)
            }
            return bytes
        }
    }
    let fields: [Field]

    /// The engine owns this builder only during its read transaction. Its lookup dictionary
    /// is discarded on publication; the browser retains just the immutable field table.
    struct Builder {
        private var ids: [String: Int] = [:]
        private var fields: [Field] = []
        init() {}
        init(_ table: NotebookSearchTextTable) {
            fields = table.fields
            ids = Dictionary(fields.enumerated().map { ($0.element.text, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
        mutating func intern(_ text: String) -> Int {
            if let id = ids[text] { return id }
            let id = fields.count
            fields.append(.init(text)); ids[text] = id
            return id
        }
        func finish() -> NotebookSearchTextTable { .init(fields: fields) }
    }

    /// A query term owns one byte per distinct field, independent of how many owners reuse it.
    /// Multi-term queries discard each term's cache before the next, bounding temporary memory
    /// by the material size rather than by the user's query length times that size.
    struct Matcher {
        let table: NotebookSearchTextTable
        let term: String
        let asciiTerm: [UInt8]?
        private let prefixes: [Int]
        private var decisions: [UInt8]
        init(table: NotebookSearchTextTable, term: String, locale: String) {
            self.table = table; self.term = term
            let language = Locale(identifier: locale).language.languageCode?.identifier
            asciiTerm = language != "tr" && language != "az" ? Field.foldASCII(term) : nil
            var prefixes = Array(repeating: 0, count: asciiTerm?.count ?? 0)
            if let bytes = asciiTerm, bytes.count > 1 {
                var matched = 0
                for index in 1..<bytes.count {
                    while matched > 0 && bytes[index] != bytes[matched] { matched = prefixes[matched - 1] }
                    if bytes[index] == bytes[matched] { matched += 1 }
                    prefixes[index] = matched
                }
            }
            self.prefixes = prefixes
            decisions = .init(repeating: 0, count: table.fields.count)
        }
        mutating func contains(_ id: Int) -> Bool {
            if decisions[id] != 0 { return decisions[id] == 1 }
            let field = table.fields[id]
            let result: Bool
            if let text = field.ascii, let needle = asciiTerm {
                result = containsASCII(text, needle)
            } else { result = field.text.localizedStandardContains(term) }
            decisions[id] = result ? 1 : 2
            return result
        }

        /// Both operands are ASCII, so a byte match retains literal substring semantics.
        /// Prefix fallback keeps long/repeated user input linear rather than quadratic, and
        /// avoids bridging hundreds of thousands of short fields into Foundation per query.
        private func containsASCII(_ text: [UInt8], _ needle: [UInt8]) -> Bool {
            guard !needle.isEmpty else { return true }
            guard needle.count <= text.count else { return false }
            var matched = 0
            for byte in text {
                while matched > 0 && byte != needle[matched] { matched = prefixes[matched - 1] }
                if byte == needle[matched] { matched += 1 }
                if matched == needle.count { return true }
            }
            return false
        }
    }
}
