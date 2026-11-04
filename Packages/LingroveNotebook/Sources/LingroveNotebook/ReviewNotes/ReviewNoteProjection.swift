import Foundation

/// Deterministic corpus-to-note binding. Only custom fields are read from the note's own
/// values; all other fields follow the exact sense/example identity. Missing optional sources
/// yield empty fields, letting the template's conditional sections choose their presentation.
public nonisolated enum ReviewNoteProjection {
    public static func fields(note: ReviewNote, type: ReviewNoteType, entry: VocabularyEntry,
                              sense: VocabularySense) throws -> [String: String] {
        guard note.noteTypeID == type.id, note.entryID == entry.id,
              note.senseID == sense.id || sense.mergedFrom.contains(note.senseID) else {
            throw ReviewTemplateError.sourceUnavailable
        }
        try ReviewTemplateRenderer.validate(type)
        let example = sense.examples.first { $0.id == note.exampleID }
        var result: [String: String] = [:]
        for field in type.fields {
            let value: String
            switch field.source {
            case .expression: value = text(entry.expression)
            case .meaning: value = text(sense.meaning)
            case .sentence: value = text(example?.text ?? "")
            case .translation: value = text(example?.translation ?? "")
            case .notes: value = text(sense.note)
            case .richContent: value = richHTML(sense.content ?? [])
            case .custom: value = note.customFields[field.id.uuidString.lowercased()] ?? ""
            }
            result[field.name] = value
        }
        return result
    }
    public static func richHTML(_ blocks: [VocabularyContentBlock]) -> String {
        blocks.map { block in
            switch block.content {
            case let .image(image, caption):
                return "<figure><img src=\"" + image.filename + "\" alt=\"" + ReviewTemplateRenderer.escapeHTML(caption)
                    + "\">" + (caption.isEmpty ? "" : "<figcaption>" + text(caption) + "</figcaption>") + "</figure>"
            case let .text(value):
                var body = text(value.text)
                if value.bold { body = "<strong>" + body + "</strong>" }
                if value.italic { body = "<em>" + body + "</em>" }
                switch value.style {
                case .heading: return "<h3>" + body + "</h3>"
                case .bullet: return "<ul><li>" + body + "</li></ul>"
                case .paragraph: return "<p>" + body + "</p>"
                }
            }
        }.joined()
    }
    private static func text(_ value: String) -> String {
        ReviewTemplateRenderer.escapeHTML(value).replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// The default is a normal editable note type with stable identities, so every caller can
/// use the same template rather than maintaining native and exported versions independently.
public nonisolated enum ReviewNoteDefaults {
    private static func id(_ suffix: String) -> UUID {
        guard let value = UUID(uuidString: "13735E31-0725-4CED-9504-" + suffix) else { preconditionFailure("Invalid built-in ID") }
        return value
    }
    public static var type: ReviewNoteType {
        .init(id: id("000000000001"), name: "Expression and context", fields: [
            .init(id: id("000000000011"), name: "Expression", source: .expression),
            .init(id: id("000000000012"), name: "Meaning", source: .meaning),
            .init(id: id("000000000013"), name: "Sentence", source: .sentence),
            .init(id: id("000000000014"), name: "Translation", source: .translation),
            .init(id: id("000000000015"), name: "Notes", source: .notes),
            .init(id: id("000000000016"), name: "RichContent", source: .richContent)
        ], templates: [.init(id: id("000000000021"), name: "Recognition",
            front: "{{#Expression}}<div class=\"expression\">{{Expression}}</div>{{/Expression}}",
            back: """
            {{FrontSide}}<hr id="answer"><div class="meaning">{{Meaning}}</div>
            {{#Sentence}}<section class="context"><div>{{Sentence}}</div>
            {{#Translation}}<div class="translation">{{Translation}}</div>{{/Translation}}</section>{{/Sentence}}
            {{#RichContent}}<section class="rich-content">{{RichContent}}</section>{{/RichContent}}
            {{#Notes}}<section class="notes">{{Notes}}</section>{{/Notes}}
            """)], css: css)
    }
    public static let css = """
        :root { color-scheme: light dark; }
        body { margin:0; font:17px/1.65 -apple-system,sans-serif; color:light-dark(#242529,#eceef2);
          background:light-dark(#ffffff,#242529); overflow-wrap:anywhere; }
        .card { box-sizing:border-box; padding:28px; max-width:760px; margin:auto; }
        .expression { font:500 38px/1.3 Georgia,serif; margin:8px 0 28px; }
        .meaning { font-size:23px; font-weight:600; margin:24px 0; }
        .context { padding:20px; border-radius:12px; background:light-dark(#f4f5f7,#303238); margin:24px 0; }
        .translation { font-size:15px; color:light-dark(#62666e,#b5b9c2); margin-top:12px; }
        .rich-content,.notes { margin:24px 0; } .notes { font-size:15px; }
        hr { border:0; border-top:1px solid light-dark(#dedfe3,#47494f); margin:24px 0; }
        img { display:block; max-width:100%; max-height:280px; object-fit:contain; margin:16px auto; border-radius:10px; }
        @media(max-width:480px) { .card{padding:20px}.expression{font-size:32px}.meaning{font-size:21px} }
        """
}
