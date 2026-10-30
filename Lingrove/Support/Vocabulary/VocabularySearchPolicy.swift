import CryptoKit
import Foundation
import NaturalLanguage

/// Pure material construction and rank fusion, shared by the window and search tests. Meanings
/// contribute only adopted assertions; browsing or searching never creates semantic relations.
nonisolated enum VocabularySearchPolicy {
    static func documents(entries: [VocabularyEntry], semantics: VocabularySemanticIndex) -> [VocabularySearchDocument] {
        let nodes = Dictionary(uniqueKeysWithValues: semantics.nodes.filter {
            $0.provenance.status == .confirmed
        }.map { ($0.id, $0) })
        let mappings = Dictionary(grouping: semantics.mappings.filter { $0.provenance.status == .confirmed }, by: \.senseID)
        let cues = Dictionary(uniqueKeysWithValues: semantics.cues.map { ($0.id, $0.text) })
        let targets = Dictionary(grouping: semantics.cueTargets.filter { $0.provenance.status == .confirmed }, by: \.nodeID)
        return entries.flatMap { entry in entry.senses.map { sense in
            var fields = [entry.expression, entry.dictionaryForm, sense.meaning]
                + sense.standaloneMeanings.map(\.text) + sense.alternateMeanings.map(\.text)
            // Context captures deliberately leave the core summary empty. Their accepted short
            // interpretations are definitions too; include those meanings, never source sentences
            // or sentence translations, so an unclassified contextual collection stays retrievable.
            fields += sense.examples.prefix(8).map(\.meaning)
            for mapping in (mappings[sense.id] ?? []).prefix(8) {
                guard let node = nodes[mapping.nodeID] else { continue }
                fields += node.labels.map(\.text) + [node.definition]
                fields += (targets[node.id] ?? []).prefix(12).compactMap { cues[$0.cueID] }
            }
            var seen = Set<String>()
            fields = fields.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(384)) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            // A bounded per-sense payload keeps each native operation short and prevents one
            // verbose definition from dominating other meanings or exhausting the context.
            let text = String(fields.joined(separator: "\n").prefix(2_000))
            return .init(selection: .init(entryID: entry.id, senseID: sense.id), expression: entry.expression,
                dictionaryForm: entry.dictionaryForm, meaning: sense.displayTitle, language: entry.language,
                fields: fields, text: text, fingerprint: fingerprint(text))
        } }
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func queryText(_ query: String) -> String {
        "Instruct: Retrieve saved expressions that match the intended meaning, across languages.\nQuery: "
            + String(query.prefix(1_000))
    }

    static func keywordScore(_ document: VocabularySearchDocument, query: String) -> Double {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return 0 }
        let expressions = [document.expression, document.dictionaryForm].map(normalized)
        if expressions.contains(query) { return 100 }
        if expressions.contains(where: { containsPhrase(query, in: $0) }) { return 80 }
        let fields = document.fields.map(normalized)
        if fields.contains(query) { return 60 }
        return fields.contains { containsPhrase(query, in: $0) } ? 40 : 0
    }

    /// A literal phrase must occupy whole words, in one meaning field. Scattered tokens across
    /// different definitions lose relationships such as negation; substrings like "on" in
    /// "postpone" are not expression matches. NLTokenizer also supplies unspaced-script boundaries.
    private static func containsPhrase(_ query: String, in field: String) -> Bool {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = field
        var starts = Set<String.Index>(), ends = Set<String.Index>()
        tokenizer.enumerateTokens(in: field.startIndex..<field.endIndex) { range, _ in
            starts.insert(range.lowerBound); ends.insert(range.upperBound)
            return true
        }
        var remaining = field.startIndex..<field.endIndex
        while let range = field.range(of: query, range: remaining) {
            if starts.contains(range.lowerBound), ends.contains(range.upperBound) { return true }
            remaining = range.upperBound..<field.endIndex
        }
        return false
    }

    /// Admission precedes reciprocal rank fusion: a position cannot prove relevance. Strong
    /// literal matches remain independent of vectors, including when the model is unavailable.
    /// Notes and source sentences are deliberately absent from both retrieval branches.
    static func hits(documents: [VocabularySearchDocument], query: String,
                     similarities: [UUID: Float] = [:], limit: Int = 8) -> [VocabularySearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else { return [] }
        // Only the currently filtered collection defines the best candidate. Scores from a
        // different language/tag scope must not raise this scope's admission threshold.
        let cutoff = VocabularySearchRelevancePolicy.cutoff(for: documents.compactMap { similarities[$0.id] })
        var lexical: [(document: VocabularySearchDocument, score: Double)] = []
        var semantic: [(document: VocabularySearchDocument, score: Float)] = []
        for document in documents {
            let score = keywordScore(document, query: query)
            let value = similarities[document.id] ?? -.infinity
            let admitted = VocabularySearchRelevancePolicy.isValid(value) && value >= cutoff
            if admitsLiteral(score, hasVectors: !similarities.isEmpty, semanticAdmitted: admitted) {
                lexical.append((document, score))
            }
            if admitted { semantic.append((document, value)) }
        }
        lexical.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.document.id.uuidString < $1.document.id.uuidString
        }
        semantic.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.document.id.uuidString < $1.document.id.uuidString
        }
        let scores = fusedScores(lexical: lexical, semantic: semantic)
        var result: [VocabularySearchHit] = []
        for document in documents {
            if let score = scores[document.id] { result.append(.init(document: document, score: score)) }
        }
        result.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Array(result.prefix(limit))
    }

    private static func admitsLiteral(_ score: Double, hasVectors: Bool, semanticAdmitted: Bool) -> Bool {
        // Headwords and exact adopted definitions/cues stand alone. A word merely mentioned
        // inside a longer definition may be a comparison or an opposite: in hybrid search it
        // can boost an admitted vector, but cannot bypass admission. Without vectors we retain
        // bounded literal fallback, so an unavailable model does not disable ordinary lookup.
        score > 0 && (score >= 60 || !hasVectors || semanticAdmitted)
    }

    private static func fusedScores(lexical: [(document: VocabularySearchDocument, score: Double)],
                                    semantic: [(document: VocabularySearchDocument, score: Float)]) -> [UUID: Double] {
        var scores: [UUID: Double] = [:]
        for (rank, row) in lexical.prefix(100).enumerated() {
            scores[row.document.id, default: 0] += 1 / Double(60 + rank + 1)
            if row.score == 100 { scores[row.document.id, default: 0] += 1 }
        }
        for (rank, row) in semantic.prefix(100).enumerated() {
            scores[row.document.id, default: 0] += 1 / Double(60 + rank + 1)
        }
        return scores
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
