import Foundation
import Testing
@testable import LingroveNotebook

struct ReviewTemplateRendererTests {
    @Test func sharedPatternsKeepTheEstablishedUnicodeAndMarkupFallback() {
        func reference(_ html: String) -> String {
            guard html.contains("<") || html.contains("&") else { return html }
            return html.replacingOccurrences(of: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "<(br\\s*/?|/p|/div|/section|/li|/h[1-6])>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        }
        for text in ["", "Café 🐈 中文", "<p>é</p><br/>中文", "<BR>case", "<ScRiPt>x<y</sCrIpT><b>safe</b>",
                     "<style>p{color:red}</style>body", "&lt;literal&gt; &amp;lt; &#39;", "<p title='>'>value</p>", "<script>unfinished"] {
            #expect(ReviewTemplateRenderer.plainText(text) == reference(text))
        }
    }

    @Test func onePreparedDefinitionRendersIndependentNotesAndKeepsFieldValuesLiteral() throws {
        var type = ReviewNoteDefaults.type
        type.templates[0].front = "{{#Expression}}<b>{{Expression}}</b>{{/Expression}}"
        type.templates[0].back = "{{FrontSide}} / {{text:Meaning}}"
        let prepared = try ReviewTemplateRenderer.Prepared(type)
        let first = try prepared.render(templateID: type.templates[0].id,
            fields: ["Expression": "literal {{Meaning}}", "Meaning": "<b>one</b>"])
        let second = try prepared.render(templateID: type.templates[0].id,
            fields: ["Expression": "second", "Meaning": "<b>two</b>"])
        #expect(first.frontHTML == "<b>literal {{Meaning}}</b>" && first.backHTML == "<b>literal {{Meaning}}</b> / one")
        #expect(second.frontHTML == "<b>second</b>" && second.backHTML == "<b>second</b> / two")
        #expect(throws: ReviewTemplateError.self) {
            try prepared.render(templateID: type.templates[0].id, fields: ["Unexpected": "value"])
        }
        #expect(throws: ReviewTemplateError.self) { try prepared.render(templateID: UUID(), fields: [:]) }
    }

    @Test func nestedConditionsFrontSideAndLiteralFieldBraces() throws {
        var type = ReviewNoteDefaults.type
        type.templates[0].front = "{{#Expression}}<b>{{Expression}}</b>{{^Meaning}}missing{{/Meaning}}{{/Expression}}"
        type.templates[0].back = "{{FrontSide}}<p>{{text:Meaning}}</p>"
        let card = try ReviewTemplateRenderer.render(type: type, template: type.templates[0], fields: [
            "Expression": "literal {{Meaning}}", "Meaning": "<b>port</b> &amp; dock"
        ])
        #expect(card.frontHTML == "<b>literal {{Meaning}}</b>")
        #expect(card.backHTML == "<b>literal {{Meaning}}</b><p>port &amp; dock</p>")
    }
    @Test func missingAndImageOnlyFieldsUseConditions() throws {
        var type = ReviewNoteDefaults.type
        type.templates[0].front = "{{#RichContent}}yes{{/RichContent}}{{^Notes}}empty{{/Notes}}"
        let card = try ReviewTemplateRenderer.render(type: type, template: type.templates[0],
            fields: ["RichContent": "<img src=\"local.png\">", "Notes": "<p><br></p>"])
        #expect(card.frontHTML == "yesempty")
    }
    @Test func invalidTemplatesFailBeforeExpansion() throws {
        for source in ["{{#Meaning}}open", "{{/Meaning}}", "{{cloze:Meaning}}", "{{Unknown}}", "{{FrontSide}}"] {
            var type = ReviewNoteDefaults.type; type.templates[0].front = source
            #expect(throws: ReviewTemplateError.self) { try ReviewTemplateRenderer.validate(type) }
        }
    }
    @Test func editingCSSPreservesTemplateIdentityAndGeneratedContent() throws {
        let original = ReviewNoteDefaults.type
        var next = original; next.css += "\n.meaning{font-size:28px}"; next.revision += 1
        let first = try ReviewTemplateRenderer.render(type: original, template: original.templates[0], fields: ["Expression": "harbor"])
        let second = try ReviewTemplateRenderer.render(type: next, template: next.templates[0], fields: ["Expression": "harbor"])
        #expect(original.id == next.id && original.templates[0].id == next.templates[0].id)
        #expect(first.frontHTML == second.frontHTML && first.css != second.css)
    }

    @Test func allBuiltInPresetsRenderAsIndependentTypes() throws {
        let base = ReviewNoteDefaults.type
        #expect(ReviewNoteDefaults.presets.count == 4)
        for preset in ReviewNoteDefaults.presets {
            let applied = ReviewNoteDefaults.makeType(preset, basedOn: base)
            try ReviewTemplateRenderer.validate(applied)
            #expect(applied.id != base.id)
            #expect(Set(applied.templates.map(\.id)).isDisjoint(with: base.templates.map(\.id)))
            #expect(ReviewNoteDefaults.matches(preset, type: applied))
            for template in applied.templates where template.enabled {
                let rendered = try ReviewTemplateRenderer.render(type: applied, template: template, fields: [
                    "Expression": "serendipity",
                    "Meaning": "fortunate discovery by chance",
                    "Sentence": "Finding that book was pure serendipity.",
                    "Translation": "找到那本书纯粹是意外的惊喜。",
                    "Notes": "Coined by Horace Walpole."
                ])
                #expect(!rendered.frontHTML.isEmpty && !rendered.backHTML.isEmpty)
            }
        }
    }

    @Test func presetsBindRenamedAndMissingFieldsBySource() throws {
        var source = ReviewNoteDefaults.type
        let expression = try #require(source.fields.firstIndex { $0.source == .expression })
        let meaning = try #require(source.fields.firstIndex { $0.source == .meaning })
        // Swapping names catches cascaded token replacements. Repurposing Translation
        // catches collisions between a new field and a reused field with the same name.
        source.fields[expression].name = "Meaning"
        source.fields[meaning].name = "Translation"
        source.fields.removeAll { $0.source == .translation }
        let preset = try #require(ReviewNoteDefaults.presets.first { $0.id == "context-immersion" })
        let type = ReviewNoteDefaults.makeType(preset, basedOn: source)
        let translation = try #require(type.fields.first { $0.source == .translation })
        #expect(translation.name != "Translation")
        #expect(type.fields.contains(source.fields[expression]))
        #expect(type.fields.contains(source.fields[meaning]))
        let template = try #require(type.templates.first)
        let rendered = try ReviewTemplateRenderer.render(type: type, template: template, fields: [
            "Meaning": "harbor", "Translation": "sheltered water", translation.name: "港湾"
        ])
        #expect(rendered.frontHTML.contains("harbor"))
        #expect(!rendered.frontHTML.contains("sheltered water"))
        #expect(rendered.backHTML.contains("sheltered water") && rendered.backHTML.contains("港湾"))
        #expect(ReviewNoteDefaults.matches(preset, type: type))
    }
}
