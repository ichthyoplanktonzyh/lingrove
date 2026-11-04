import Foundation
import Testing
@testable import LingroveNotebook

struct ReviewTemplateRendererTests {
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
}
