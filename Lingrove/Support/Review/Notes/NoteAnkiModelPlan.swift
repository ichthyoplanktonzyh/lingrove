import Foundation
import LingroveNotebook

/// Pure model transitions preserve template IDs/order and field storage. Each remote step has
/// a complete expected result, so retries can recognize a committed prefix. Removing a local
/// field archives its Anki value; it never invokes Anki's destructive field/template removal.
nonisolated enum NoteAnkiModelPlan {
    /// A temporary name makes swapping two field names safe without overwriting either value.
    private struct Rename { let old: String; let temporary: String; let new: String }
    static func make(
        type: ReviewNoteType, export: ReviewNoteAnkiExport, name: String,
        previous: NoteAnkiJournal.Model?
    ) throws -> NoteAnkiJournal.Plan {
        var templates = Dictionary(
            uniqueKeysWithValues: type.templates.map { template in
                (
                    template.id.uuidString.lowercased(),
                    AnkiValue.object([
                        "Front": .string(template.enabled ? template.front : "<!-- disabled -->"),
                        "Back": .string(template.back.isEmpty ? "<!-- empty -->" : template.back)
                    ])
                )
            })
        guard let baseline = previous?.shape, let oldType = previous?.type else {
            let shape = NoteAnkiJournal.Shape(
                fields: export.fieldNames, order: type.templates.map { $0.id.uuidString.lowercased() },
                templates: templates, css: export.css)
            let values = type.templates.map { template -> AnkiValue in
                var fields = templates[template.id.uuidString.lowercased()]!.object!
                fields["Name"] = .string(template.id.uuidString.lowercased())
                return .object(fields)
            }
            return .init(
                type: type, before: nil,
                steps: [
                    .init(
                        action: "createModel",
                        parameters: [
                            "modelName": .string(name), "inOrderFields": .list(shape.fields), "css": .string(shape.css),
                            "isCloze": .bool(false), "cardTemplates": .array(values)
                        ], after: shape)
                ])
        }
        for (key, old) in baseline.templates where templates[key] == nil {
            templates[key] = .object([
                "Front": .string("<!-- disabled -->"), "Back": old.object?["Back"] ?? .string("<!-- empty -->")
            ])
        }
        var current = baseline
        var steps: [NoteAnkiJournal.Step] = []
        func append(_ action: String, _ parameters: [String: AnkiValue]) {
            steps.append(.init(action: action, parameters: parameters, after: current))
        }
        func rename(_ old: String, _ new: String) throws {
            guard let index = current.fields.firstIndex(of: old), !current.fields.contains(new) else {
                throw VocabularyError.editConflict
            }
            current.fields[index] = new
            current.templates = current.templates.mapValues { value in
                guard let sides = value.object else { return value }
                return .object(
                    sides.mapValues { side in
                        guard var text = side.string else { return side }
                        for prefix in ["", "text:", "#", "^", "/"] {
                            text = text.replacingOccurrences(
                                of: "{{" + prefix + old + "}}", with: "{{" + prefix + new + "}}")
                        }
                        return .string(text)
                    })
            }
            append(
                "modelFieldRename",
                ["modelName": .string(name), "oldFieldName": .string(old), "newFieldName": .string(new)])
        }
        let renames = type.fields.compactMap { field -> Rename? in
            guard let old = oldType.fields.first(where: { $0.id == field.id }), old.name != field.name else {
                return nil
            }
            return Rename(old: old.name, temporary: "LG_" + field.id.uuidString.replacingOccurrences(of: "-", with: ""), new: field.name)
        }
        for change in renames { try rename(change.old, change.temporary) }
        for change in renames { try rename(change.temporary, change.new) }
        for field in type.fields where !current.fields.contains(field.name) {
            current.fields.append(field.name)
            append("modelFieldAdd", ["modelName": .string(name), "fieldName": .string(field.name)])
        }
        for template in type.templates {
            let key = template.id.uuidString.lowercased()
            let value = templates[key]!
            if current.templates[key] == nil {
                current.templates[key] = value
                current.order.append(key)
                var object = value.object!
                object["Name"] = .string(key)
                append("modelTemplateAdd", ["modelName": .string(name), "template": .object(object)])
            }
        }
        let updates = templates.filter { current.templates[$0.key] != $0.value }
        if !updates.isEmpty {
            current.templates.merge(updates) { _, next in next }
            append("updateModelTemplates", ["model": .object(["name": .string(name), "templates": .object(updates)])])
        }
        if current.css != export.css {
            current.css = export.css
            append("updateModelStyling", ["model": .object(["name": .string(name), "css": .string(export.css)])])
        }
        return .init(type: type, before: baseline, steps: steps)
    }
}
