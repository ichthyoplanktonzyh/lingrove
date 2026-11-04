import Foundation
@testable import Lingrove

/// Stateful legacy-protocol fixture. Model structure, notes and card identities survive calls,
/// including replies deliberately lost after commit. No real Anki profile or transport is used.
actor NoteAnkiFake: AnkiConnecting {
    struct Note { var model: String; var fields: [String: String] }
    struct Card { var note: Int64; var ordinal: Int; var suspended = false; var deck = "Default" }
    var models: [String: NoteAnkiJournal.Shape] = [:]
    var notes: [Int64: Note] = [:]
    var cards: [Int64: Card] = [:]
    var next: Int64 = 1000
    var lost: String?
    func lose(_ action: String) { lost = action }
    func count() -> Int { notes.count }
    func modelCount() -> Int { models.count }
    func cardIDs() -> Set<Int64> { Set(cards.keys) }
    func fields() -> [String: String] { notes.values.first?.fields ?? [:] }
    func edit(_ field: String, _ value: String) { if let id = notes.keys.first { notes[id]?.fields[field] = value } }
    func customizeCSS() { if let key = models.keys.first { models[key]?.css = "manual" } }
    func suspendManually(_ ids: Set<Int64>) { for id in ids { cards[id]?.suspended = true } }
    func suspendedCount() -> Int { cards.values.filter(\.suspended).count }
    func allSuspended() -> Bool { !cards.isEmpty && cards.values.allSatisfy(\.suspended) }
    func perform(_ action: String, params: [String: AnkiValue], connection: AnkiConnection) async throws -> AnkiValue {
        let result = try dispatch(action, params)
        if lost == action { lost = nil; throw URLError(.networkConnectionLost) }
        return result
    }
    private func dispatch(_ action: String, _ p: [String: AnkiValue]) throws -> AnkiValue {
        let name = p["modelName"]?.string ?? ""
        switch action {
        case "getActiveProfile": return .string("Synthetic")
        case "deckNames": return .list(["Default", "Other"])
        case "modelNames": return .list(Array(models.keys))
        case "modelFieldNames": return .list(models[name]!.fields)
        case "modelTemplates": return .object(models[name]!.templates)
        case "modelStyling": return .object(["css": .string(models[name]!.css)])
        case "findModelsByName":
            return .array((p["modelNames"]?.array ?? []).compactMap { value in
                guard let model = models[value.string ?? ""] else { return nil }
                return .object(["tmpls": .array(model.order.enumerated().map { index, name in
                    .object(["name": .string(name), "ord": .number(Double(index))])
                })])
            })
        case "createModel":
            let templates = p["cardTemplates"]!.array!
            models[name] = .init(fields: p["inOrderFields"]!.array!.map { $0.string! },
                order: templates.map { $0.object!["Name"]!.string! },
                templates: Dictionary(uniqueKeysWithValues: templates.map { row in
                    let value = row.object!; return (value["Name"]!.string!, .object(["Front": value["Front"]!, "Back": value["Back"]!]))
                }), css: p["css"]!.string!)
        case "modelFieldAdd": models[name]!.fields.append(p["fieldName"]!.string!)
        case "modelFieldRename":
            let old = p["oldFieldName"]!.string!, new = p["newFieldName"]!.string!
            let index = models[name]!.fields.firstIndex(of: old)!
            models[name]!.fields[index] = new
            models[name]!.templates = models[name]!.templates.mapValues { row in .object(row.object!.mapValues { side in
                var text = side.string!
                for prefix in ["", "#", "^", "/", "text:"] { text = text.replacingOccurrences(of: "{{" + prefix + old + "}}", with: "{{" + prefix + new + "}}") }
                return .string(text)
            }) }
            for id in notes.keys where notes[id]!.model == name { notes[id]!.fields[new] = notes[id]!.fields.removeValue(forKey: old) }
        case "modelTemplateAdd":
            let value = p["template"]!.object!, key = value["Name"]!.string!
            models[name]!.order.append(key); models[name]!.templates[key] = .object(["Front": value["Front"]!, "Back": value["Back"]!])
            for id in notes.keys where notes[id]!.model == name { next += 1; cards[next] = .init(note: id, ordinal: models[name]!.order.count - 1) }
        case "updateModelTemplates":
            let value = p["model"]!.object!, key = value["name"]!.string!
            models[key]!.templates.merge(value["templates"]!.object!) { _, new in new }
        case "updateModelStyling":
            let value = p["model"]!.object!; models[value["name"]!.string!]!.css = value["css"]!.string!
        case "findNotes":
            if let query = p["query"]?.string, query.hasPrefix("note:") {
                let model = String(query.dropFirst(6).dropLast())
                return .array(notes.filter { $0.value.model == model }.keys.map { .number(Double($0)) })
            }
            return .array(notes.filter { (p["query"]?.string ?? "").contains($0.value.fields["LingroveNoteID"] ?? "missing") }.keys.map { .number(Double($0)) })
        case "notesInfo":
            return .array(p["notes"]!.array!.map { id in
                guard let note = notes[id.integer!] else { return .object([:]) }
                return .object(["noteId": id, "modelName": .string(note.model), "fields": .object(note.fields.mapValues { .object(["value": .string($0)]) })])
            })
        case "addNote":
            let value = p["note"]!.object!; next += 1; let id = next
            notes[id] = .init(model: value["modelName"]!.string!, fields: value["fields"]!.object!.mapValues { $0.string! })
            for ordinal in models[notes[id]!.model]!.order.indices { next += 1; cards[next] = .init(note: id, ordinal: ordinal) }
            return .number(Double(id))
        case "updateNoteFields":
            let note = p["note"]!.object!
            notes[note["id"]!.integer!]!.fields.merge(note["fields"]!.object!.mapValues { $0.string! }) { _, new in new }
        case "findCards":
            let id = Int64(p["query"]!.string!.dropFirst(4))!
            return .array(cards.filter { $0.value.note == id }.keys.map { .number(Double($0)) })
        case "cardsInfo": return .array(p["cards"]!.array!.map { id in .object(["cardId": id, "ord": .number(Double(cards[id.integer!]!.ordinal)), "deckName": .string(cards[id.integer!]!.deck)]) })
        case "changeDeck": for id in p["cards"]!.array! { cards[id.integer!]!.deck = p["deck"]!.string! }
        case "areSuspended": return .array(p["cards"]!.array!.map { .bool(cards[$0.integer!]!.suspended) })
        case "suspend", "unsuspend": for id in p["cards"]!.array! { cards[id.integer!]!.suspended = action == "suspend" }; return .bool(true)
        case "storeMediaFile": return p["filename"]!
        default: throw AnkiReviewError.message("Unexpected fake action: " + action)
        }
        return .null
    }
}
