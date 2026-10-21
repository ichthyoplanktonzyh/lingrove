import Foundation

/// A regular Anki note generates two conditional card types. Gap text is prepared locally,
/// rather than mixing Anki's special Cloze note type with an ordinary recognition template.
/// Automatic creation leaves existing templates alone. Explicit upgrades accept only recognized
/// Lingrove templates, preserving customizations users make in Anki.
nonisolated enum AnkiNoteTemplate {
    static let legacyCSS = """
    .card { font-family: -apple-system, sans-serif; font-size: 22px; line-height: 1.6;
      text-align: left; color: #202124; background: #fff; padding: 24px; }
    b { color: #087cff; } .meaning { font-weight: 600; } .extra { font-size: 17px; opacity: .75; }
    .nightMode.card { color: #eee; background: #202124; } hr { opacity: .2; }
    """
    static let legacyRecognitionFront = """
    {{#Recognition}}{{#Sentence}}{{Sentence}}{{/Sentence}}{{^Sentence}}{{Expression}}{{/Sentence}}{{/Recognition}}
    """
    static let legacyGapFront = "{{#GapPrompt}}{{GapPrompt}}<div class='extra'>{{Meaning}}</div>{{/GapPrompt}}"
    static let legacyRecognitionBack = """
    {{FrontSide}}<hr id=answer><div class='meaning'>{{Meaning}}</div><div>{{Expression}}</div>
    <div class='extra'>{{Translation}}</div><div class='extra'>{{Notes}}</div><div class='extra'>{{Explanation}}</div>
    """
    static let legacyGapBack = """
    {{FrontSide}}<hr id=answer><div>{{GapAnswer}}</div><div>{{Sentence}}</div>
    <div class='meaning'>{{Meaning}}</div><div>{{Expression}}</div>
    <div class='extra'>{{Translation}}</div><div class='extra'>{{Notes}}</div><div class='extra'>{{Explanation}}</div>
    """
    static let css = """
    .card { font-family: -apple-system, sans-serif; font-size: 22px; line-height: 1.65;
      text-align: left; color: #202124; background: #fff; padding: 20px; overflow-wrap: anywhere; }
    .prompt { margin-bottom: 16px; } b { color: #087cff; font-weight: 650; }
    .meaning { font-size: 1.1em; font-weight: 600; margin: 12px 0; }
    .expression { font-weight: 600; margin-top: 12px; } .extra { font-size: .8em; opacity: .78; margin: 10px 0; }
    .audio { margin: 8px 0; } hr { border: 0; border-top: 1px solid #8885; margin: 20px 0; }
    .nightMode.card { color: #eee; background: #202124; }
    @media (prefers-color-scheme: dark) { .card { color: #eee; background: #202124; } }
    """
    static let recognitionFront = """
    {{#Recognition}}<div class="prompt">{{#Sentence}}{{Sentence}}{{/Sentence}}{{^Sentence}}{{Expression}}{{/Sentence}}</div>{{/Recognition}}
    """
    // Answers and recordings appear only after revealing the gap. A translated hint or an
    // auto-playing full sentence could otherwise reveal the very word being recalled.
    static let gapFront = "{{#GapPrompt}}<div class='prompt'>{{GapPrompt}}</div>{{/GapPrompt}}"
    static let recognitionBack = """
    {{FrontSide}}<hr id=answer><div class='meaning'>{{Meaning}}</div>
    <div class='expression'>{{Expression}}</div><div class='audio'>{{ExpressionAudio}}</div>
    <div class='audio'>{{SentenceAudio}}</div><div class='extra'>{{Translation}}</div>
    <div class='extra'>{{Notes}}</div><div class='extra'>{{Explanation}}</div>
    """
    static let gapBack = """
    {{FrontSide}}<hr id=answer><div class='prompt'>{{Sentence}}</div>
    <div class='meaning'>{{Meaning}}</div><div class='expression'>{{Expression}}</div>
    <div class='audio'>{{ExpressionAudio}}</div><div class='audio'>{{SentenceAudio}}</div>
    <div class='extra'>{{Translation}}</div><div class='extra'>{{Notes}}</div><div class='extra'>{{Explanation}}</div>
    """
    static var templates: [String: AnkiValue] { templateValues(legacy: false) }
    static var legacyTemplates: [String: AnkiValue] { templateValues(legacy: true) }
    private static func templateValues(legacy: Bool) -> [String: AnkiValue] {
        ["Recognition": .object(["Front": .string(legacy ? legacyRecognitionFront : recognitionFront),
                                  "Back": .string(legacy ? legacyRecognitionBack : recognitionBack)]),
         "Gap": .object(["Front": .string(legacy ? legacyGapFront : gapFront),
                          "Back": .string(legacy ? legacyGapBack : gapBack)])]
    }

    /// Only our own static templates are interpreted. Field values are inserted after conditional
    /// processing in a single pass, so user text containing braces never becomes template code.
    static func preview(fields: [String: String], gap: Bool, back: Bool, css: String = Self.css) -> String {
        let front = render(gap ? gapFront : recognitionFront, fields: fields)
        let sides = fields.merging(["FrontSide": front]) { _, value in value }
        let body = back ? render(gap ? gapBack : recognitionBack, fields: sides) : front
        let silent = body.replacingOccurrences(of: "\\[sound:[^\\]]+\\]", with: "", options: .regularExpression)
        return "<style>" + css + "</style><div class='card'>" + silent + "</div>"
    }
    private static func render(_ template: String, fields: [String: String]) -> String {
        var text = template
        let conditional = try? NSRegularExpression(
            pattern: "\\{\\{([#^])(\\w+)\\}\\}((?:(?!\\{\\{[#^]).)*?)\\{\\{/\\2\\}\\}", options: .dotMatchesLineSeparators)
        while let match = conditional?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let source = text as NSString
            let name = source.substring(with: match.range(at: 2)), inverse = source.substring(with: match.range(at: 1)) == "^"
            let present = !(fields[name] ?? "").isEmpty
            let value = present != inverse ? source.substring(with: match.range(at: 3)) : ""
            text = source.replacingCharacters(in: match.range, with: value)
        }
        let variable = try? NSRegularExpression(pattern: "\\{\\{(\\w+)\\}\\}")
        for match in (variable?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).reversed() {
            let name = (text as NSString).substring(with: match.range(at: 1))
            text = (text as NSString).replacingCharacters(in: match.range, with: fields[name] ?? "")
        }
        return text
    }
}
