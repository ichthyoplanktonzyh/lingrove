import Foundation

/// Deterministic preparation rules turn one saved sense/usage into review material. This layer
/// starts no model, reads no dictionary, and escapes all text before it can become Anki HTML.
nonisolated enum ReviewCardPolicy {
    static func initialPlan(_ sense: VocabularySense) -> ReviewPlan {
        sense.review?.plan ?? ReviewPlan(exampleID: sense.examples.first?.id, includeSenseContent: true)
    }

    static func content(entry: VocabularyEntry, sense: VocabularySense, plan: ReviewPlan) throws -> ReviewCardContent {
        let example = sense.examples.first { $0.id == plan.exampleID }
        guard plan.exampleID == nil || example != nil else {
            throw AnkiReviewError.message(String(localized: "Choose a review example again.", table: "Vocabulary"))
        }
        let contextual = example?.meaning.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = contextual.isEmpty ? sense.meaning : contextual
        let preferred = sense.meaningOrigin == .user || example == nil ? sense.meaning : fallback
        let answer = (plan.answer ?? preferred).trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = example?.text ?? ""
        let ranges = example?.ranges ?? []
        let gap = gap(in: sentence, ranges: ranges, kind: entry.kind)
        let blocks = plan.includeSenseContent == true ? sense.content ?? [] : []
        try VocabularyContentPolicy.validate(blocks)
        guard !answer.isEmpty || VocabularyContentPolicy.meaningful(blocks) else {
            throw AnkiReviewError.message(String(localized: "Add a review answer before sending.", table: "Vocabulary"))
        }
        guard plan.recognition || plan.gap, !plan.gap || gap != nil else {
            throw AnkiReviewError.message(String(localized: "Choose valid expression positions for a gap card.", table: "Vocabulary"))
        }
        let records = example?.explanations ?? sense.explanations
        let explanation = plan.includeExplanation ? records.last?.result.explanation ?? "" : ""
        return .init(expression: entry.expression, answer: answer, sentence: sentence, ranges: ranges,
            translation: example?.translation ?? "", explanation: explanation, notes: plan.includeNotes ? sense.note : "",
            gapPrompt: gap?.prompt ?? "", gapAnswer: gap?.answer ?? "", recognition: plan.recognition, gap: plan.gap, senseContent: blocks)
    }

    /// Multiple spans preserve discontinuous expressions. Validate grapheme boundaries and
    /// nonoverlap before replacing backwards, so emoji or repeated words cannot shift a blank.
    static func gap(in text: String, ranges: [VocabularyTextRange], kind: VocabularyEntry.Kind) -> (prompt: String, answer: String)? {
        let ordered = ranges.map(\.nsRange).sorted { $0.location < $1.location }
        guard kind != .sentence, !ordered.isEmpty, ordered.allSatisfy({ VocabularyPolicy.valid($0, in: text) }),
              zip(ordered, ordered.dropFirst()).allSatisfy({ NSMaxRange($0) <= $1.location }),
              ordered.reduce(0, { $0 + $1.length }) < text.utf16.count else { return nil }
        let source = text as NSString
        let answer = ordered.map { source.substring(with: $0) }.joined(separator: " … ")
        let result = NSMutableString(string: text)
        for range in ordered.reversed() { result.replaceCharacters(in: range, with: "___") }
        return (result as String, answer)
    }

    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\n", with: "<br>")
    }

    static func sentenceHTML(_ content: ReviewCardContent) -> String {
        let source = content.sentence as NSString
        let ranges = content.ranges.map(\.nsRange).sorted { $0.location < $1.location }
        guard ranges.allSatisfy({ VocabularyPolicy.valid($0, in: content.sentence) }),
              zip(ranges, ranges.dropFirst()).allSatisfy({ NSMaxRange($0) <= $1.location }) else { return html(content.sentence) }
        var output = "", cursor = 0
        for range in ranges {
            output += html(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            output += "<b>" + html(source.substring(with: range)) + "</b>"
            cursor = NSMaxRange(range)
        }
        output += html(source.substring(from: cursor))
        return output
    }

    static func values(_ content: ReviewCardContent, identity: UUID) -> [ReviewField: String] {
        [.identity: identity.uuidString.lowercased(), .expression: html(content.expression),
         .meaning: html(content.answer) + VocabularyContentPolicy.html(content.senseContent),
         .sentence: sentenceHTML(content), .translation: html(content.translation), .explanation: html(content.explanation),
         .notes: html(content.notes), .recognition: content.recognition ? "1" : "",
         .gapPrompt: content.gap ? html(content.gapPrompt) : "", .gapAnswer: content.gap ? html(content.gapAnswer) : ""]
    }
}
