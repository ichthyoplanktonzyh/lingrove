import Foundation

/// A bounded Anki-compatible substitution interpreter. It parses the template before inserting
/// fields, so braces inside user content remain literal. Supported syntax is explicit: fields,
/// text: filters, nested #/^ conditionals and FrontSide. Unsupported constructs fail, not vanish.
public nonisolated enum ReviewTemplateRenderer {
    private indirect enum Node { case literal(String), field(String, Bool), section(String, Bool, [Node]) }

    public static func render(type: ReviewNoteType, template: ReviewCardTemplate,
                              fields: [String: String]) throws -> ReviewRenderedCard {
        try validate(type)
        guard type.templates.contains(template), fields.keys.allSatisfy({ key in type.fields.contains { $0.name == key } })
        else { throw ReviewTemplateError.invalidDefinition }
        let names = Set(type.fields.map(\.name))
        let front = try expand(parse(template.front, names: names, allowsFront: false), fields: fields)
        let back = try expand(parse(template.back, names: names, allowsFront: true), fields: fields.merging(["FrontSide": front]) { _, rhs in rhs })
        guard front.utf8.count <= 1_048_576, back.utf8.count <= 1_048_576 else { throw ReviewTemplateError.invalidDefinition }
        return .init(frontHTML: front, backHTML: back, css: type.css, fields: fields)
    }

    public static func validate(_ type: ReviewNoteType) throws {
        let fields = type.fields, templates = type.templates
        guard !type.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              type.name.utf8.count <= 1024, type.revision > 0, (1...64).contains(fields.count),
              (1...16).contains(templates.count), Set(fields.map(\.id)).count == fields.count,
              Set(fields.map(\.name)).count == fields.count, Set(templates.map(\.id)).count == templates.count,
              type.css.utf8.count <= 131_072 else { throw ReviewTemplateError.invalidDefinition }
        let forbidden = CharacterSet(charactersIn: "{}:#^/<>\n\r")
        for field in fields {
            guard !field.name.isEmpty, field.name == field.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  field.name.utf8.count <= 128, !["FrontSide", "Tags", "Type", "Deck", "Subdeck", "CardFlag", "Card", "LingroveNoteID"].contains(field.name),
                  field.name.rangeOfCharacter(from: forbidden) == nil else { throw ReviewTemplateError.invalidDefinition }
        }
        let names = Set(fields.map(\.name))
        for template in templates {
            guard !template.name.isEmpty, template.name.utf8.count <= 1024,
                  template.front.utf8.count <= 131_072, template.back.utf8.count <= 131_072 else {
                throw ReviewTemplateError.invalidDefinition
            }
            _ = try parse(template.front, names: names, allowsFront: false)
            _ = try parse(template.back, names: names, allowsFront: true)
        }
    }

    private static func parse(_ text: String, names: Set<String>, allowsFront: Bool) throws -> [Node] {
        var cursor = text.startIndex
        func nodes(until expected: String?, depth: Int) throws -> [Node] {
            guard depth < 32 else { throw ReviewTemplateError.invalidDefinition }
            var result: [Node] = []
            while cursor < text.endIndex {
                guard let start = text.range(of: "{{", range: cursor..<text.endIndex) else {
                    result.append(.literal(String(text[cursor...]))); cursor = text.endIndex; break
                }
                if start.lowerBound > cursor { result.append(.literal(String(text[cursor..<start.lowerBound]))) }
                guard let end = text.range(of: "}}", range: start.upperBound..<text.endIndex) else {
                    throw ReviewTemplateError.unbalancedSection(String(text[start.lowerBound...]))
                }
                let token = String(text[start.upperBound..<end.lowerBound])
                cursor = end.upperBound
                if token.hasPrefix("/") {
                    guard String(token.dropFirst()) == expected else { throw ReviewTemplateError.unbalancedSection(token) }
                    return result
                }
                if token.hasPrefix("#") || token.hasPrefix("^") {
                    let name = String(token.dropFirst())
                    guard names.contains(name) else { throw ReviewTemplateError.unknownField(name) }
                    result.append(.section(name, token.hasPrefix("^"), try nodes(until: name, depth: depth + 1)))
                } else {
                    let plain = token.hasPrefix("text:")
                    let name = plain ? String(token.dropFirst(5)) : token
                    if name.contains(":") { throw ReviewTemplateError.unsupportedSyntax(token) }
                    guard names.contains(name) || (allowsFront && name == "FrontSide") else {
                        throw ReviewTemplateError.unknownField(name)
                    }
                    result.append(.field(name, plain))
                }
            }
            if let expected { throw ReviewTemplateError.unbalancedSection(expected) }
            return result
        }
        return try nodes(until: nil, depth: 0)
    }

    private static func expand(_ nodes: [Node], fields: [String: String]) throws -> String {
        var output = ""
        for node in nodes {
            switch node {
            case let .literal(value): output += value
            case let .field(name, plain): output += plain ? escapeHTML(plainText(fields[name] ?? "")) : fields[name] ?? ""
            case let .section(name, inverse, children):
                let value = fields[name] ?? ""
                let present = !plainText(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || value.range(of: "<(img|audio)\\b", options: [.regularExpression, .caseInsensitive]) != nil
                if present != inverse { output += try expand(children, fields: fields) }
            }
            guard output.utf8.count <= 1_048_576 else { throw ReviewTemplateError.invalidDefinition }
        }
        return output
    }

    public static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Plain fallback is for copy/speech/search, never a second rendering engine. Decode entities
    /// after removing markup so an escaped user literal such as &lt;tag&gt; stays visible text.
    public static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<(br\\s*/?|/p|/div|/section|/li|/h[1-6])>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
