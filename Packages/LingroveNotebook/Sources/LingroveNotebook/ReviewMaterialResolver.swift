import Foundation
import LingroveTextRules

/// The same pure material selection feeds built-in practice and external export. It reads one
/// saved sense and its stable selected example; it owns no database, generation service or UI.
public nonisolated enum ReviewMaterialResolver {
    public static func validate(_ plan: ReviewMaterialPlan) throws {
        try VocabularyReviewValidation.validate(plan.layout)
        guard (plan.name?.utf8.count ?? 0) <= 1024, plan.audio.count <= 2,
              plan.audio.allSatisfy({ kind, value in
                  plan.layout.audioKinds.contains(kind) && value.reference.isValid && value.reference.image == nil &&
                  [value.textHash, value.fingerprint].allSatisfy { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
              }) else { throw VocabularyError.invalidContent }
    }

    public static func resolve(entry: VocabularyEntry, sense: VocabularySense, plan: ReviewMaterialPlan,
                               previewBack: Bool? = nil) throws -> ReviewMaterialContent {
        try validate(plan)
        let example = sense.examples.first { $0.id == plan.exampleID }
        func resolve(_ part: ReviewCardPart) throws -> ReviewResolvedPart {
            func text(_ value: String?) throws -> ReviewResolvedPart {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ReviewMaterialError.missingContent(part.source)
                }
                return .text(value)
            }
            switch part.source {
            case .expression: return try text(entry.expression)
            case .meaning:
                let value = sense.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                return try text(value.isEmpty ? example?.meaning : value)
            case .sentence: return try text(example?.text)
            case .translation: return try text(example?.translation)
            case .contextualMeaning: return try text(example?.meaning)
            case .explanation:
                let records = plan.exampleID == nil ? sense.explanations : example?.explanations
                return try text(records?.last?.result.explanation)
            case .notes: return try text(sense.note)
            case .gapSentence: return try text(example.flatMap { gap(in: $0.text, ranges: $0.ranges, kind: entry.kind)?.prompt })
            case .expressionAudio: _ = try text(entry.expression); return .audio(.expression)
            case .sentenceAudio: _ = try text(example?.text); return .audio(.sentence)
            case .custom:
                guard VocabularyContentPolicy.meaningful(part.content) else { return try text(nil) }
                return .blocks(captions(part.content, shown: part.showCaption))
            case .senseText, .senseImage:
                guard let block = sense.content?.first(where: { $0.id == part.blockID && matches($0, source: part.source) }) else { return try text(nil) }
                return .blocks(captions([block], shown: part.showCaption))
            }
        }
        guard previewBack != nil || !plan.layout.front.isEmpty && !plan.layout.back.isEmpty else { throw ReviewMaterialError.emptyFace }
        return .init(front: try previewBack == true ? [] : plan.layout.front.map(resolve),
                     back: try previewBack == false ? [] : plan.layout.back.map(resolve))
    }

    public static func audioText(_ kind: ReviewAudioKind, entry: VocabularyEntry, sense: VocabularySense,
                                 plan: ReviewMaterialPlan) -> String? {
        kind == .expression ? entry.expression : sense.examples.first { $0.id == plan.exampleID }?.text
    }

    /// Validate Unicode grapheme boundaries before replacing selected UTF-16 spans backwards.
    /// A repeated expression blanks only its selected occurrence, including discontinuous spans.
    public static func gap(in text: String, ranges: [VocabularyTextRange], kind: VocabularyEntry.Kind) -> (prompt: String, answer: String)? {
        let ordered = ranges.map(\.nsRange).sorted { $0.location < $1.location }
        guard kind != .sentence, !ordered.isEmpty, ordered.allSatisfy({ UTF16TextRangePolicy.isValid($0, in: text) }),
              zip(ordered, ordered.dropFirst()).allSatisfy({ NSMaxRange($0) <= $1.location }),
              ordered.reduce(0, { $0 + $1.length }) < text.utf16.count else { return nil }
        let source = text as NSString
        let answer = ordered.map { source.substring(with: $0) }.joined(separator: " … ")
        let result = NSMutableString(string: text)
        for range in ordered.reversed() { result.replaceCharacters(in: range, with: "___") }
        return (result as String, answer)
    }
    public static func preset(_ index: Int) -> ReviewLayout {
        switch index {
        case 1: .init(front: [.init(source: .gapSentence)], back: [.init(source: .expression), .init(source: .meaning)])
        case 2: .init(front: [.init(source: .senseImage)], back: [.init(source: .expression), .init(source: .meaning)])
        case 3: .init()
        default: .init(front: [.init(source: .expression)], back: [.init(source: .meaning)])
        }
    }
    public static func portable(_ layout: ReviewLayout) -> ReviewLayout {
        func copy(_ part: ReviewCardPart) -> ReviewCardPart {
            var result = part; result.id = UUID(); result.blockID = nil
            result.content = part.content.map { var copy = $0; copy.id = UUID(); return copy }
            return result
        }
        return .init(front: layout.front.map(copy), back: layout.back.map(copy))
    }
    public static func applying(_ layout: ReviewLayout, to sense: VocabularySense) -> ReviewLayout {
        var result = portable(layout)
        func bind(_ part: ReviewCardPart) -> ReviewCardPart {
            var part = part
            if part.source == .senseText || part.source == .senseImage {
                part.blockID = sense.content?.first { matches($0, source: part.source) }?.id
            }
            return part
        }
        result.front = result.front.map(bind); result.back = result.back.map(bind)
        return result
    }
    public static func matches(_ block: VocabularyContentBlock, source: ReviewContentSource) -> Bool {
        switch (source, block.content) {
        case (.senseImage, .image), (.senseText, .text): true
        default: false
        }
    }
    private static func captions(_ blocks: [VocabularyContentBlock], shown: Bool) -> [VocabularyContentBlock] {
        blocks.map { var block = $0
            if case let .image(image, _) = block.content, !shown { block.content = .image(image, caption: "") }
            return block
        }
    }
}
