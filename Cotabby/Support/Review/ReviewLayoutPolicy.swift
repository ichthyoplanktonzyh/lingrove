import Foundation

/// Pure resolution is the shared boundary between saved source references and card HTML.
/// Missing sources fail visibly instead of producing an empty question or a misleading answer.
nonisolated enum ReviewLayoutPolicy {
    static let model = "Lingrove Flexible v1"
    static let mapping: [ReviewField: String] = [.identity: "LingroveID", .expression: "Front", .meaning: "Back"]
    static let css = AnkiNoteTemplate.css + "\n.card section { margin: 12px 0; }" +
        " img { max-width:100%; max-height:480px; object-fit:contain; }"
    static let templates: [String: AnkiValue] = ["Card": .object(["Front": .string("{{Front}}"), "Back": .string("{{Back}}")])]

    static func preset(_ index: Int) -> ReviewLayout {
        switch index {
        case 1: .init(front: [.init(source: .gapSentence)], back: [.init(source: .expression), .init(source: .meaning)])
        case 2: .init(front: [.init(source: .senseImage)], back: [.init(source: .expression), .init(source: .meaning)])
        case 3: .init()
        default: .init(front: [.init(source: .expression)], back: [.init(source: .meaning)])
        }
    }

    static func validate(_ layout: ReviewLayout) throws {
        guard layout.parts.count <= 64, Set(layout.parts.map(\.id)).count == layout.parts.count else {
            throw VocabularyError.invalidContent
        }
        for part in layout.parts {
            guard part.source == .custom || part.content.isEmpty else { throw VocabularyError.invalidContent }
            try VocabularyContentPolicy.validate(part.content)
        }
        try VocabularyContentPolicy.validate(layout.customContent)
    }

    static func portable(_ layout: ReviewLayout) -> ReviewLayout {
        func copy(_ part: ReviewCardPart) -> ReviewCardPart {
            var result = part; result.id = UUID(); result.blockID = nil
            result.content = part.content.map { block in var copy = block; copy.id = UUID(); return copy }
            return result
        }
        return .init(front: layout.front.map(copy), back: layout.back.map(copy))
    }

    static func applying(_ layout: ReviewLayout, to sense: VocabularySense) -> ReviewLayout {
        var result = portable(layout)
        func bind(_ part: ReviewCardPart) -> ReviewCardPart {
            var part = part
            if part.source == .senseText || part.source == .senseImage {
                part.blockID = sense.content?.first(where: { matches($0, source: part.source) })?.id
            }
            return part
        }
        result.front = result.front.map(bind); result.back = result.back.map(bind)
        return result
    }

    static func matches(_ block: VocabularyContentBlock, source: ReviewContentSource) -> Bool {
        switch (source, block.content) {
        case (.senseImage, .image), (.senseText, .text): true
        default: false
        }
    }

    static func content(entry: VocabularyEntry, sense: VocabularySense, plan: ReviewPlan,
                        previewBack: Bool? = nil) throws -> ReviewCardContent {
        guard let layout = plan.layout else { throw VocabularyError.invalidContent }
        try validate(layout)
        let example = sense.examples.first { $0.id == plan.exampleID }
        // Only parts that actually require an example depend on it. Removing an unused example
        // cannot invalidate an image-only card, while a selected sentence never silently changes.
        // This finite source dispatch deliberately stays together to keep missing-source rules identical.
        // swiftlint:disable:next cyclomatic_complexity
        func resolve(_ part: ReviewCardPart) throws -> ReviewResolvedPart {
            func text(_ value: String?) throws -> ReviewResolvedPart {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AnkiReviewError.message(String(localized: "Card content is missing. Choose its source again.",
                        table: "Vocabulary") + " · " + part.source.label)
                }
                return .text(value)
            }
            switch part.source {
            case .expression: return try text(entry.expression)
            case .meaning:
                let core = sense.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                return try text(core.isEmpty ? example?.meaning : core)
            case .sentence: return try text(example?.text)
            case .translation: return try text(example?.translation)
            case .contextualMeaning: return try text(example?.meaning)
            case .explanation:
                let records = plan.exampleID == nil ? sense.explanations : example?.explanations
                return try text(records?.last?.result.explanation)
            case .notes: return try text(sense.note)
            case .gapSentence:
                return try text(example.flatMap { ReviewCardPolicy.gap(in: $0.text, ranges: $0.ranges, kind: entry.kind)?.prompt })
            case .expressionAudio: return .audio(.expression)
            case .sentenceAudio:
                _ = try text(example?.text); return .audio(.sentence)
            case .custom:
                guard VocabularyContentPolicy.meaningful(part.content) else { return try text(nil) }
                return .blocks(part.content.map { block in
                    var block = block
                    if case let .image(image, _) = block.content, !part.showCaption { block.content = .image(image, caption: "") }
                    return block
                })
            case .senseText, .senseImage:
                guard var block = sense.content?.first(where: { $0.id == part.blockID && matches($0, source: part.source) }) else {
                    return try text(nil)
                }
                if case let .image(image, _) = block.content, !part.showCaption { block.content = .image(image, caption: "") }
                return .blocks([block])
            }
        }
        guard previewBack != nil || !layout.front.isEmpty && !layout.back.isEmpty else {
            throw AnkiReviewError.message(String(localized: "Add content to both sides of the card.", table: "Vocabulary"))
        }
        let front = try previewBack == true ? [] : layout.front.map(resolve)
        let back = try previewBack == false ? [] : layout.back.map(resolve)
        let blocks = (front + back).flatMap { part -> [VocabularyContentBlock] in
            if case let .blocks(blocks) = part { blocks } else { [] }
        }
        return .init(expression: entry.expression, answer: sense.meaning, sentence: example?.text ?? "", ranges: [],
            translation: example?.translation ?? "", explanation: "", notes: "", gapPrompt: "", gapAnswer: "",
            recognition: true, gap: false, senseContent: blocks, front: front, back: back)
    }

    static func html(_ parts: [ReviewResolvedPart], audio: [ReviewField: String]) -> String {
        parts.map { part in
            let body = switch part {
            case let .text(text): ReviewCardPolicy.html(text)
            case let .blocks(blocks): VocabularyContentPolicy.html(blocks)
            case let .audio(kind): audio[kind.field] ?? ""
            }
            return "<section>" + body + "</section>"
        }.joined()
    }

    static func preview(_ parts: [ReviewResolvedPart]) -> String {
        // Preview audio uses a visible label; actual playback borrows the existing TTS service.
        let audio = Dictionary(uniqueKeysWithValues: ReviewAudioKind.allCases.map { ($0.field, "🔊 " + ReviewCardPolicy.html($0.label)) })
        return "<style>" + css + "</style><div class='card'>" + html(parts, audio: audio) + "</div>"
    }
}
