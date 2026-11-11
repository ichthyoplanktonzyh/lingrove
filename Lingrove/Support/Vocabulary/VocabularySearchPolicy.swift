import LingroveNotebook
import CryptoKit
import Foundation
import NaturalLanguage

/// Pure material construction and rank fusion, shared by the window and search tests. Meanings
/// contribute only adopted assertions; browsing or searching never creates semantic relations.
nonisolated enum VocabularySearchPolicy {
    private static let hexadecimal = Array("0123456789abcdef".utf8)
    static func documents(entries: [VocabularyEntry], semantics: VocabularySemanticIndex) -> [VocabularySearchDocument] {
        let material = VocabularySearchMaterial(semantics)
        return entries.flatMap { entry in entry.senses.map { sense in
            document(entry: entry, sense: sense, fields: material.fields(entry: entry, sense: sense))
        } }
    }

    /// Full builds and delta preparation share these bounded text/normalization rules.
    static func document(entry: VocabularyEntry, sense: VocabularySense, fields: [String],
                         normalizing normalize: (String) -> String = normalized) -> VocabularySearchDocument {
        var seen = Set<String>()
        let fields = fields.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(384)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let text = String(fields.joined(separator: "\n").prefix(2_000))
        return .init(selection: .init(entryID: entry.id, senseID: sense.id), expression: entry.expression,
            dictionaryForm: entry.dictionaryForm, meaning: sense.displayTitle, language: entry.language,
            fields: fields, text: text, fingerprint: fingerprint(text), tags: sense.tags,
            normalizedExpressions: [entry.expression, entry.dictionaryForm].map(normalize),
            normalizedFields: fields.map(normalize))
    }

    static func meaningDocuments(entries: [VocabularyEntry], semantics: VocabularySemanticIndex) -> [VocabularyMeaningSearchDocument] {
        let material = VocabularySearchMaterial(semantics)
        return VocabularyMeaningBrowserProjection.items(index: semantics, entries: entries, includeEmpty: false).compactMap { item in
            guard item.node.provenance.status == .confirmed, !item.selections.isEmpty else { return nil }
            return meaningDocument(node: item.node, senseIDs: item.selections.map(\.senseID), terms: material.terms(item.node))
        }
    }

    static func meaningDocument(node: VocabularyMeaningNode, senseIDs: [UUID], terms: [String],
                                normalizing normalize: (String) -> String = normalized) -> VocabularyMeaningSearchDocument? {
        let text = String((terms + [node.definition]).map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(384))
        }.filter { !$0.isEmpty }.joined(separator: "\n").prefix(2_000))
        guard !text.isEmpty else { return nil }
        return .init(node: node, senseIDs: senseIDs, lookupTerms: terms,
            text: text, fingerprint: fingerprint(text), normalizedTerms: terms.map(normalize))
    }

    static func results(documents: [VocabularySearchDocument], meanings: [VocabularyMeaningSearchDocument],
                        query: String, similarities: [UUID: Float] = [:],
                        meaningSimilarities: [UUID: Float] = [:]) -> VocabularySearchResults {
        let term = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !term.isEmpty else { return .init() }
        var matcher = PhraseMatcher(term)
        let exact = documents.filter { expressions($0).contains(term) }
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        // Only nodes with visible senses participate in admission. A filtered-out node cannot
        // raise the similarity threshold or surface a result the learner has filtered away.
        let candidates = meanings.filter { $0.senseIDs.contains { byID[$0] != nil } }
        let literal = candidates.compactMap { meaning -> (meaning: VocabularyMeaningSearchDocument, rank: Int)? in
            let terms = meaning.normalizedTerms.isEmpty ? meaning.lookupTerms.map(normalized) : meaning.normalizedTerms
            if terms.contains(term) { return (meaning, 2) }
            if terms.contains(where: { matcher.contains(in: $0) }) { return (meaning, 1) }
            return nil
        }
        let matched: [VocabularyMeaningSearchDocument]
        if !literal.isEmpty {
            matched = literal.sorted { $0.rank > $1.rank }.map(\.meaning)
        } else if exact.isEmpty {
            let scores = candidates.compactMap { meaning -> (meaning: VocabularyMeaningSearchDocument, score: Float)? in
                guard let score = meaningSimilarities[meaning.id], VocabularySearchRelevancePolicy.isValid(score) else { return nil }
                return (meaning, score)
            }
            let cutoff = VocabularySearchRelevancePolicy.cutoff(for: scores.map(\.score))
            matched = scores.filter { $0.score >= cutoff }.sorted { $0.score > $1.score }.map(\.meaning)
        } else {
            matched = []
        }
        let groups = matched.map { meaning in
            VocabularySearchResults.MeaningGroup(node: meaning.node, documents: meaning.senseIDs.compactMap { byID[$0] }.sorted {
                let order = $0.expression.localizedStandardCompare($1.expression)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            })
        }
        let expanded = Set(exact.map(\.id) + groups.flatMap { $0.documents.map(\.id) })
        let other = hits(documents: documents, similarities: similarities, limit: documents.count, matcher: &matcher)
            .map(\.document).filter { !expanded.contains($0.id) }
        return .init(exact: exact, groups: groups, other: other)
    }

    static func fingerprint(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(text.utf8)) {
            bytes.append(hexadecimal[Int(byte >> 4)])
            bytes.append(hexadecimal[Int(byte & 15)])
        }
        // The alphabet above guarantees valid ASCII; this conversion cannot be lossy.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    static func queryText(_ query: String) -> String {
        "Instruct: Retrieve saved expressions that match the intended meaning, across languages.\nQuery: "
            + String(query.prefix(1_000))
    }

    static func keywordScore(_ document: VocabularySearchDocument, query: String) -> Double {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var matcher = PhraseMatcher(query)
        return keywordScore(document, matcher: &matcher)
    }

    private static func expressions(_ document: VocabularySearchDocument) -> [String] {
        document.normalizedExpressions.isEmpty
            ? [document.expression, document.dictionaryForm].map(normalized) : document.normalizedExpressions
    }

    private static func keywordScore(_ document: VocabularySearchDocument, matcher: inout PhraseMatcher) -> Double {
        let query = matcher.query
        guard !query.isEmpty else { return 0 }
        let expressions = expressions(document)
        if expressions.contains(query) { return 100 }
        if expressions.contains(where: { matcher.contains(in: $0) }) { return 80 }
        let fields = document.normalizedFields.isEmpty ? document.fields.map(normalized) : document.normalizedFields
        if fields.contains(query) { return 60 }
        return fields.contains { matcher.contains(in: $0) } ? 40 : 0
    }

    /// One query reuses phrase decisions for shared headwords/meaning labels and for fields
    /// encountered again during rank fusion. Nothing survives the query, so changing a field
    /// or a filter cannot reuse stale admission. NaturalLanguage still owns word boundaries.
    private struct PhraseMatcher {
        let query: String
        private let ascii: Bool
        private var matches: [String: Bool] = [:]
        init(_ query: String) { self.query = query; ascii = query.utf8.allSatisfy { $0 < 128 } }
        mutating func contains(in field: String) -> Bool {
            if let result = matches[field] { return result }
            // An ASCII query has no alternative canonical decomposition. Literal lookup
            // avoids Foundation's canonical-equivalence search on every normalized field.
            let result = VocabularySearchPolicy.containsPhrase(query, in: field, literal: ascii)
            matches[field] = result
            return result
        }
    }

    /// A literal phrase must occupy whole words, in one meaning field. Scattered tokens across
    /// different definitions lose relationships such as negation; substrings like "on" in
    /// "postpone" are not expression matches. NLTokenizer also supplies unspaced-script boundaries.
    private static func containsPhrase(_ query: String, in field: String, literal: Bool) -> Bool {
        // Most fields do not contain the query at all. Running NaturalLanguage's tokenizer
        // on every one of those fields made a short search scan take seconds in large corpora.
        let options: String.CompareOptions = literal ? .literal : []
        guard field.range(of: query, options: options) != nil else { return false }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = field
        var starts = Set<String.Index>(), ends = Set<String.Index>()
        tokenizer.enumerateTokens(in: field.startIndex..<field.endIndex) { range, _ in
            starts.insert(range.lowerBound); ends.insert(range.upperBound)
            return true
        }
        var remaining = field.startIndex..<field.endIndex
        while let range = field.range(of: query, options: options, range: remaining) {
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
        var matcher = PhraseMatcher(normalized(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        return hits(documents: documents, similarities: similarities, limit: limit, matcher: &matcher)
    }

    private static func hits(documents: [VocabularySearchDocument], similarities: [UUID: Float],
                             limit: Int, matcher: inout PhraseMatcher) -> [VocabularySearchHit] {
        // Only the currently filtered collection defines the best candidate. Scores from a
        // different language/tag scope must not raise this scope's admission threshold.
        let cutoff = VocabularySearchRelevancePolicy.cutoff(for: documents.compactMap { similarities[$0.id] })
        var lexical: [(document: VocabularySearchDocument, score: Double)] = []
        var semantic: [(document: VocabularySearchDocument, score: Float)] = []
        for document in documents {
            if Task.isCancelled { return [] }
            let score = keywordScore(document, matcher: &matcher)
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
        for (rank, row) in lexical.enumerated() {
            scores[row.document.id, default: 0] += 1 / Double(60 + rank + 1)
            if row.score == 100 { scores[row.document.id, default: 0] += 1 }
        }
        for (rank, row) in semantic.enumerated() {
            scores[row.document.id, default: 0] += 1 / Double(60 + rank + 1)
        }
        return scores
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
