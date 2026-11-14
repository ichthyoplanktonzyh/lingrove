import Foundation
import LingroveNotebook

/// A browser/archive owns this disposable text index. It retains only the selected entries'
/// searchable fields, updating changed owners when a new revision arrives. ASCII fields use
/// literal lowercase lookup; other scripts keep Foundation's localized matching contract.
nonisolated struct VocabularyLiteralSearchIndex {
    private struct Field {
        let original: String
        let ascii: String?
        init(_ value: String) {
            original = value
            ascii = value.utf8.allSatisfy { $0 < 128 } ? value.lowercased() : nil
        }
    }
    private var inputs: [UUID: VocabularyEntry] = [:]
    private var fields: [UUID: [Field]] = [:]

    mutating func prepare(_ entries: [VocabularyEntry]) {
        let live = Set(entries.map(\.id))
        inputs = inputs.filter { live.contains($0.key) }
        fields = fields.filter { live.contains($0.key) }
        var reused: [String: Field] = [:]
        for entry in entries where inputs[entry.id] != entry {
            fields[entry.id] = VocabularyPolicy.searchFields(entry).map { text in
                if let field = reused[text] { return field }
                let field = Field(text); reused[text] = field; return field
            }
            inputs[entry.id] = entry
        }
    }

    func matching(_ entries: [VocabularyEntry], query: String) -> [VocabularyEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return entries }
        let language = Locale.current.language.languageCode?.identifier
        let usesASCIIFolding = language != "tr" && language != "az"
        var decisions: [String: [String: Bool]] = [:]
        return entries.filter { entry in
            guard let fields = fields[entry.id] else { return VocabularyPolicy.matches(entry, query: query) }
            return terms.allSatisfy { term in
                let ascii = usesASCIIFolding && term.utf8.allSatisfy({ $0 < 128 }) ? term.lowercased() : nil
                return fields.contains { field in
                    if let result = decisions[term]?[field.original] { return result }
                    let result: Bool
                    if let ascii, let text = field.ascii {
                        result = text.range(of: ascii, options: .literal) != nil
                    } else { result = field.original.localizedStandardContains(term) }
                    decisions[term, default: [:]][field.original] = result
                    return result
                }
            }
        }
    }
}
