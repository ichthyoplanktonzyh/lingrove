import LingroveNotebook
import Foundation

/// This Anki adapter borrows target-neutral source resolution and owns only the legacy export
/// projection, safe HTML and Anki template metadata. Built-in preparation never depends on it.
nonisolated enum ReviewLayoutPolicy {
    static let model = "Lingrove Flexible v1"
    static let mapping: [ReviewField: String] = [.identity: "LingroveID", .expression: "Front", .meaning: "Back"]
    static let css = AnkiNoteTemplate.css + "\n.card section { margin: 12px 0; }" +
        " img { max-width:100%; max-height:480px; object-fit:contain; }"
    static let templates: [String: AnkiValue] = ["Card": .object(["Front": .string("{{Front}}"), "Back": .string("{{Back}}")])]

    static func preset(_ index: Int) -> ReviewLayout { ReviewMaterialResolver.preset(index) }
    static func validate(_ layout: ReviewLayout) throws { try VocabularyReviewValidation.validate(layout) }
    static func portable(_ layout: ReviewLayout) -> ReviewLayout { ReviewMaterialResolver.portable(layout) }
    static func applying(_ layout: ReviewLayout, to sense: VocabularySense) -> ReviewLayout {
        ReviewMaterialResolver.applying(layout, to: sense)
    }
    static func matches(_ block: VocabularyContentBlock, source: ReviewContentSource) -> Bool {
        ReviewMaterialResolver.matches(block, source: source)
    }

    /// Only this adapter translates neutral resolved material into Anki's legacy export value.
    /// Source selection and missing-content policy live in the shared resolver for both tools.
    static func content(entry: VocabularyEntry, sense: VocabularySense, plan: ReviewPlan,
                        previewBack: Bool? = nil) throws -> ReviewCardContent {
        guard let layout = plan.layout else { throw VocabularyError.invalidContent }
        let resolved: ReviewMaterialContent
        do {
            resolved = try ReviewMaterialResolver.resolve(entry: entry, sense: sense,
                plan: .init(name: plan.name, layout: layout, exampleID: plan.exampleID), previewBack: previewBack)
        } catch let issue as ReviewMaterialError {
            throw AnkiReviewError.message(ReviewMaterialCopy.message(issue))
        }
        let example = sense.examples.first { $0.id == plan.exampleID }
        let blocks = (resolved.front + resolved.back).flatMap { part -> [VocabularyContentBlock] in
            if case let .blocks(blocks) = part { blocks } else { [] }
        }
        return .init(expression: entry.expression, answer: sense.meaning, sentence: example?.text ?? "", ranges: [],
            translation: example?.translation ?? "", explanation: "", notes: "", gapPrompt: "", gapAnswer: "",
            recognition: true, gap: false, senseContent: blocks, front: resolved.front, back: resolved.back)
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
