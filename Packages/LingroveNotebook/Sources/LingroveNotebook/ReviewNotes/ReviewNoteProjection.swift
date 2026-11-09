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
                let body = value.segments.map { segment in
                    var part = text(segment.text)
                    if segment.bold { part = "<strong>" + part + "</strong>" }
                    if segment.italic { part = "<em>" + part + "</em>" }
                    return part
                }.joined()
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
    /// A complete visual and question layout for creating an independent note type.
    public struct Preset: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let badge: String
        public let templates: [ReviewCardTemplate]
        public let css: String

        fileprivate init(
            id: String,
            title: String,
            subtitle: String,
            badge: String,
            templates: [ReviewCardTemplate],
            css: String
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.badge = badge
            self.templates = templates
            self.css = css
        }
    }

    private static func id(_ suffix: String) -> UUID {
        guard let value = UUID(uuidString: "13735E31-0725-4CED-9504-" + suffix) else { preconditionFailure("Invalid built-in ID") }
        return value
    }

    private static let standardFields: [ReviewNoteField] = [
        .init(id: id("000000000011"), name: "Expression", source: .expression),
        .init(id: id("000000000012"), name: "Meaning", source: .meaning),
        .init(id: id("000000000013"), name: "Sentence", source: .sentence),
        .init(id: id("000000000014"), name: "Translation", source: .translation),
        .init(id: id("000000000015"), name: "Notes", source: .notes),
        .init(id: id("000000000016"), name: "RichContent", source: .richContent)
    ]

    // This definition is synchronized by ID and revision, including when it is only a
    // bundled fallback. Preset styling must have its own persisted identity.
    public static var type: ReviewNoteType {
        .init(id: id("000000000001"), name: "Expression and context", fields: standardFields, templates: [.init(id: id("000000000021"), name: "Recognition",
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

    private static var editorialRecognitionTemplate: ReviewCardTemplate {
        .init(
            id: id("000000000021"),
            name: "Recognition",
            front: """
            <article class="lingrove-stage">
              <div class="kicker">EXPRESSION</div>
              {{#Expression}}<div class="expression">{{Expression}}</div>{{/Expression}}
            </article>
            """,
            back: """
            {{FrontSide}}<hr id="answer">
            <section class="answer-body">
              <div class="section-block">
                <div class="section-label">MEANING</div>
                <div class="meaning">{{Meaning}}</div>
              </div>
              {{#Sentence}}<section class="context"><div class="sentence">{{Sentence}}</div>
              {{#Translation}}<div class="translation">{{Translation}}</div>{{/Translation}}</section>{{/Sentence}}
              {{#RichContent}}<section class="rich-content">{{RichContent}}</section>{{/RichContent}}
              {{#Notes}}<section class="notes"><div class="section-label">NOTES</div><div>{{Notes}}</div></section>{{/Notes}}
            </section>
            """
        )
    }

    private static let editorialCSS = """
        :root { color-scheme: light dark; }
        body {
          margin: 0;
          font: 16px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          color: light-dark(#1d2026, #edf0f5);
          background: light-dark(#fbfaf7, #1d1f24);
          overflow-wrap: anywhere;
          -webkit-font-smoothing: antialiased;
        }
        .card {
          box-sizing: border-box;
          padding: 34px 36px;
          max-width: 760px;
          margin: auto;
        }
        .kicker, .section-label {
          font: 600 11px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          letter-spacing: 0.10em;
          text-transform: uppercase;
          color: light-dark(#6b7280, #949ba6);
          margin-bottom: 8px;
        }
        .expression {
          font: 600 40px/1.22 "New York", "Iowan Old Style", Georgia, serif;
          letter-spacing: -0.01em;
          color: light-dark(#14171f, #f6f7f9);
          margin: 4px 0 24px;
        }
        .section-block { margin: 20px 0; }
        .meaning {
          font-size: 22px;
          font-weight: 600;
          line-height: 1.45;
          color: light-dark(#1a202c, #f0f4f8);
          margin: 6px 0 20px;
        }
        .context {
          padding: 18px 22px;
          border-radius: 12px;
          border-left: 3.5px solid light-dark(#2b6cb0, #5897fb);
          background: light-dark(#f2f0eb, #262930);
          margin: 22px 0;
        }
        .sentence {
          font: 400 17px/1.62 "New York", Georgia, serif;
          color: light-dark(#22262e, #e5e8ef);
        }
        .translation {
          font-size: 14.5px;
          color: light-dark(#5c626c, #a9b0bc);
          margin-top: 10px;
        }
        .rich-content { margin: 22px 0; }
        .notes {
          padding: 14px 18px;
          border-radius: 10px;
          background: light-dark(#f5f6f8, #23262d);
          border: 1px solid light-dark(#e3e5ea, #333741);
          font-size: 14.5px;
          color: light-dark(#424750, #c8cdd6);
          margin: 20px 0;
        }
        hr {
          border: 0;
          border-top: 1px solid light-dark(#e4e2dc, #353842);
          margin: 24px 0;
        }
        img {
          display: block;
          max-width: 100%;
          max-height: 280px;
          object-fit: contain;
          margin: 16px auto;
          border-radius: 10px;
        }
        @media(max-width:480px) {
          .card { padding: 22px; }
          .expression { font-size: 32px; }
          .meaning { font-size: 20px; }
        }
        """

    public static let contextImmersionCSS = """
        :root { color-scheme: light dark; }
        body {
          margin: 0;
          font: 16px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          color: light-dark(#1e232a, #eef1f6);
          background: light-dark(#f6f8fb, #1a1d23);
          overflow-wrap: anywhere;
          -webkit-font-smoothing: antialiased;
        }
        .card { box-sizing: border-box; padding: 32px 36px; max-width: 760px; margin: auto; }
        .kicker, .section-label {
          font: 600 11px/1.3 -apple-system, sans-serif;
          letter-spacing: 0.09em;
          text-transform: uppercase;
          color: light-dark(#4a6fa5, #79a6dc);
          margin-bottom: 8px;
        }
        .context-hero {
          padding: 22px 24px;
          border-radius: 16px;
          background: light-dark(#ffffff, #242831);
          border: 1px solid light-dark(#e1e6ef, #343946);
          box-shadow: 0 2px 10px rgba(0, 0, 0, 0.03);
          margin: 6px 0 20px;
        }
        .sentence {
          font: 500 21px/1.55 "New York", Georgia, serif;
          color: light-dark(#171b22, #f2f4f8);
        }
        .target-pill {
          display: inline-block;
          margin-top: 14px;
          padding: 5px 13px;
          border-radius: 999px;
          font-size: 14px;
          font-weight: 600;
          color: light-dark(#1e4e8c, #90cdf4);
          background: light-dark(#e8f0fe, #28364d);
        }
        .meaning { font-size: 22px; font-weight: 600; margin: 8px 0 14px; }
        .translation {
          font-size: 15px;
          color: light-dark(#525965, #aeb5c2);
          padding-left: 14px;
          border-left: 2.5px solid light-dark(#cbd5e1, #475569);
          margin: 14px 0;
        }
        .rich-content, .notes { margin: 18px 0; font-size: 14.5px; color: light-dark(#4a515c, #c2c8d4); }
        hr { border: 0; border-top: 1px solid light-dark(#dde3ec, #323743); margin: 24px 0; }
        img { display: block; max-width: 100%; max-height: 280px; object-fit: contain; margin: 16px auto; border-radius: 10px; }
        """

    public static let minimalistSwissCSS = """
        :root { color-scheme: light dark; }
        body {
          margin: 0;
          font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          color: light-dark(#111315, #f4f5f7);
          background: light-dark(#ffffff, #16171a);
          overflow-wrap: anywhere;
          -webkit-font-smoothing: antialiased;
        }
        .card { box-sizing: border-box; padding: 36px 40px; max-width: 760px; margin: auto; }
        .swiss-grid {
          border-top: 2px solid light-dark(#111315, #f4f5f7);
          padding-top: 16px;
        }
        .kicker, .section-label {
          font: 600 10.5px/1.2 ui-monospace, "SF Mono", Menlo, monospace;
          letter-spacing: 0.12em;
          text-transform: uppercase;
          color: light-dark(#6c7078, #8e939e);
          margin-bottom: 6px;
        }
        .expression {
          font: 700 42px/1.15 -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
          letter-spacing: -0.025em;
          margin: 4px 0 24px;
        }
        .meaning { font-size: 21px; font-weight: 600; margin: 6px 0 20px; }
        .context {
          padding: 16px 0;
          border-top: 1px solid light-dark(#e5e7eb, #2e3138);
          border-bottom: 1px solid light-dark(#e5e7eb, #2e3138);
          margin: 20px 0;
        }
        .sentence { font-size: 16.5px; font-weight: 500; }
        .translation { font-size: 14.5px; color: light-dark(#60656f, #9ea4b0); margin-top: 6px; }
        .rich-content, .notes { margin: 18px 0; font-size: 14px; color: light-dark(#4b5058, #b8bec9); }
        hr { border: 0; border-top: 1px solid light-dark(#d5d8de, #32353d); margin: 24px 0; }
        img { display: block; max-width: 100%; max-height: 280px; object-fit: contain; margin: 16px auto; border-radius: 6px; }
        """

    public static var presets: [Preset] {
        [
            Preset(
                id: "editorial",
                title: "Editorial Dictionary",
                subtitle: "Serif headword, structured meaning & accented quote",
                badge: "Default",
                templates: [editorialRecognitionTemplate],
                css: editorialCSS
            ),
            Preset(
                id: "context-immersion",
                title: "Context Immersion",
                subtitle: "Sentence-first prompt that anchors words in real usage",
                badge: "Context",
                templates: [
                    .init(
                        id: id("000000000021"),
                        name: "Context Recognition",
                        front: """
                        <article class="lingrove-stage">
                          <div class="kicker">IN CONTEXT</div>
                          <div class="context-hero">
                            {{#Sentence}}<div class="sentence">{{Sentence}}</div>{{/Sentence}}
                            {{^Sentence}}{{#Expression}}<div class="sentence">{{Expression}}</div>{{/Expression}}{{/Sentence}}
                            {{#Expression}}<span class="target-pill">{{Expression}}</span>{{/Expression}}
                          </div>
                        </article>
                        """,
                        back: """
                        {{FrontSide}}<hr id="answer">
                        <section class="answer-body">
                          <div class="section-label">MEANING</div>
                          <div class="meaning">{{Meaning}}</div>
                          {{#Translation}}<div class="translation">{{Translation}}</div>{{/Translation}}
                          {{#RichContent}}<section class="rich-content">{{RichContent}}</section>{{/RichContent}}
                          {{#Notes}}<section class="notes"><div class="section-label">NOTES</div><div>{{Notes}}</div></section>{{/Notes}}
                        </section>
                        """
                    )
                ],
                css: contextImmersionCSS
            ),
            Preset(
                id: "minimalist-swiss",
                title: "Swiss Minimalist",
                subtitle: "High-contrast geometric typography & monospaced labels",
                badge: "Minimal",
                templates: [
                    .init(
                        id: id("000000000021"),
                        name: "Minimal Recognition",
                        front: """
                        <article class="swiss-grid">
                          <div class="kicker">01 / EXPRESSION</div>
                          {{#Expression}}<div class="expression">{{Expression}}</div>{{/Expression}}
                        </article>
                        """,
                        back: """
                        {{FrontSide}}<hr id="answer">
                        <section class="answer-body">
                          <div class="section-label">02 / MEANING</div>
                          <div class="meaning">{{Meaning}}</div>
                          {{#Sentence}}<section class="context"><div class="sentence">{{Sentence}}</div>
                          {{#Translation}}<div class="translation">{{Translation}}</div>{{/Translation}}</section>{{/Sentence}}
                          {{#RichContent}}<section class="rich-content">{{RichContent}}</section>{{/RichContent}}
                          {{#Notes}}<section class="notes"><div class="section-label">03 / NOTES</div><div>{{Notes}}</div></section>{{/Notes}}
                        </section>
                        """
                    )
                ],
                css: minimalistSwissCSS
            ),
            Preset(
                id: "bilateral-recall",
                title: "Bilateral Recall",
                subtitle: "Two-way practice: Recognition + Active Recall card pair",
                badge: "2 Cards",
                templates: [
                    editorialRecognitionTemplate,
                    .init(
                        id: id("000000000022"),
                        name: "Active Recall",
                        front: """
                        <article class="lingrove-stage">
                          <div class="kicker">ACTIVE RECALL</div>
                          <div class="meaning">{{Meaning}}</div>
                          {{#Translation}}<div class="context"><div class="translation">{{Translation}}</div></div>{{/Translation}}
                        </article>
                        """,
                        back: """
                        {{FrontSide}}<hr id="answer">
                        <section class="answer-body">
                          <div class="section-label">TARGET EXPRESSION</div>
                          {{#Expression}}<div class="expression">{{Expression}}</div>{{/Expression}}
                          {{#Sentence}}<section class="context"><div class="sentence">{{Sentence}}</div></section>{{/Sentence}}
                          {{#RichContent}}<section class="rich-content">{{RichContent}}</section>{{/RichContent}}
                          {{#Notes}}<section class="notes"><div class="section-label">NOTES</div><div>{{Notes}}</div></section>{{/Notes}}
                        </section>
                        """
                    )
                ],
                css: editorialCSS
            )
        ]
    }

    /// Builds a new type with fresh template IDs. The source type and its enrolled cards
    /// are untouched. Matching source fields keep their IDs and names, even after a rename.
    public static func makeType(_ preset: Preset, basedOn source: ReviewNoteType) -> ReviewNoteType {
        let fields = presetFields(in: source.fields)
        let templates = boundTemplates(preset, fields: fields).map { template in
            ReviewCardTemplate(name: template.name, front: template.front, back: template.back)
        }
        return .init(name: preset.title, fields: fields, templates: templates, css: preset.css)
    }

    public static func matches(_ preset: Preset, type: ReviewNoteType) -> Bool {
        guard type.css == preset.css, type.templates.count == preset.templates.count else { return false }
        let fields = matchingFields(in: type.fields).compactMap { $0 }
        guard fields.count == standardFields.count else { return false }
        return zip(type.templates, boundTemplates(preset, fields: fields)).allSatisfy { actual, expected in
            actual.enabled && actual.name == expected.name && actual.front == expected.front && actual.back == expected.back
        }
    }

    private static func matchingFields(in existing: [ReviewNoteField]) -> [ReviewNoteField?] {
        standardFields.map { field in
            existing.first { $0.source == field.source && $0.id == field.id }
                ?? existing.first { $0.source == field.source && $0.name == field.name }
                ?? existing.first { $0.source == field.source }
        }
    }

    private static func presetFields(in existing: [ReviewNoteField]) -> [ReviewNoteField] {
        let reusable = matchingFields(in: existing)
        var usedNames = Set(reusable.compactMap { $0?.name })
        return zip(standardFields, reusable).map { field, match in
            if let match { return match }
            var name = field.name
            var suffix = 2
            while !usedNames.insert(name).inserted {
                name = field.name + " " + String(suffix)
                suffix += 1
            }
            return .init(name: name, source: field.source)
        }
    }

    private static func boundTemplates(_ preset: Preset, fields: [ReviewNoteField]) -> [ReviewCardTemplate] {
        let names = Dictionary(uniqueKeysWithValues: zip(standardFields.map(\.name), fields.map(\.name)))
        // Replace whole tokens in one pass. Two renamed fields can swap names, so
        // sequential substitutions could change a token that has already been rebound.
        let token = /\{\{(text:|[#^\/]?)([^{}]+)\}\}/
        func bind(_ html: String) -> String {
            html.replacing(token) { match in
                guard let name = names[String(match.2)] else { return String(match.0) }
                return "{{" + match.1 + name + "}}"
            }
        }
        return preset.templates.map { template in
            var result = template
            result.front = bind(template.front)
            result.back = bind(template.back)
            return result
        }
    }
}
