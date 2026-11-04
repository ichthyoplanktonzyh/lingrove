import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// Explicit sends reuse the process Anki controller's lease, credentials and profile fences.
/// The local journal precedes every remote write; verified model stages and identity-field
/// lookup recover partially committed calls. Ratings and review intervals remain owned by Anki.
@MainActor
final class NoteAnkiSender {
    let controller: AnkiReviewController
    let io: NoteAnkiIO
    init(controller: AnkiReviewController, io: NoteAnkiIO) {
        self.controller = controller
        self.io = io
    }
    struct Result {
        let noteID: Int64?
        let conflicts: [String]
        let remote: [String: String]
    }

    /// Immutable choices belong to one explicit send, not to mutable controller settings.
    private struct Options {
        let deck: String
        let choices: [String: Bool]
        let expectedRemote: [String: String]
        let moveExisting: Bool
    }
    private struct Admission { let type: ReviewNoteType; let order: [UUID]; let resume: Bool }
    private struct Record { let id: Int64; let key: String; var value: NoteAnkiJournal.Note }

    func send(
        _ material: NoteAnkiIO.Material, scope: ReviewOperationScope, deck: String,
        choices: [String: Bool] = [:], expectedRemote: [String: String] = [:], moveExisting: Bool = false
    ) async throws -> Result {
        try controller.begin(material.sense.id, cardID: material.note.id)
        do {
            let result = try await perform(
                material, scope: scope,
                options: .init(deck: deck, choices: choices, expectedRemote: expectedRemote, moveExisting: moveExisting))
            controller.finish(
                material.sense.id, cardID: material.note.id, wrote: result.conflicts.isEmpty, scope: material.scope)
            return result
        } catch {
            controller.finish(material.sense.id, cardID: material.note.id, error: error, scope: material.scope)
            throw error
        }
    }

    // Keep journal recovery and each pre/post-await scope fence adjacent to its remote write.
    // The pure model plan and field merge own decisions; this function owns ordered effects.
    // swiftlint:disable:next cyclomatic_complexity
    private func perform(_ material: NoteAnkiIO.Material, scope: ReviewOperationScope,
                         options: Options) async throws -> Result {
        let deck = options.deck, choices = options.choices
        let expectedRemote = options.expectedRemote, moveExisting = options.moveExisting
        func check() async throws {
            try await controller.verify(scope)
            try await io.validate(material)
        }
        func call(_ action: String, _ params: [String: AnkiValue]) async throws -> AnkiValue {
            try await check()
            let result = try await controller.call(action, params, scope.connection)
            try await check()
            return result
        }
        try await check()
        guard try controller.strings(await call("deckNames", [:])).contains(deck) else {
            throw VocabularyError.editConflict
        }
        let keyPrefix =
            material.scope.workspaceId + "|" + scope.connection.endpoint.absoluteString + "|" + scope.profile + "|"
        let modelKey = keyPrefix + material.type.id.uuidString
        let noteKey = keyPrefix + material.note.id.uuidString
        let modelName = "Lingrove " + material.scope.workspaceId + " " + material.type.id.uuidString.lowercased()
        var journal = try await io.journal()
        func remoteShape() async throws -> NoteAnkiJournal.Shape? {
            let names = try controller.strings(await call("modelNames", [:]))
            guard names.contains(modelName) else { return nil }
            let fields = try controller.strings(await call("modelFieldNames", ["modelName": .string(modelName)]))
            guard let templates = try await call("modelTemplates", ["modelName": .string(modelName)]).object,
                let css = try await call("modelStyling", ["modelName": .string(modelName)]).object?["css"]?.string
            else { throw controller.invalid() }
            guard let models = try await call("findModelsByName", ["modelNames": .list([modelName])]).array,
                models.count == 1, let rows = models[0].object?["tmpls"]?.array
            else { throw controller.invalid() }
            let order = try rows.map { row -> (Int, String) in
                guard let name = row.object?["name"]?.string, case .number(let index)? = row.object?["ord"],
                    index >= 0, index.rounded() == index, index < 1000
                else { throw controller.invalid() }
                return (Int(index), name)
            }.sorted { $0.0 < $1.0 }.map(\.1)
            guard Set(order) == Set(templates.keys), order.count == templates.count else { throw controller.invalid() }
            return .init(fields: fields, order: order, templates: templates, css: css)
        }
        var reconcileAllNotes = false
        func reconcileModel(_ type: ReviewNoteType, order: [UUID], resume: Bool) async throws {
            let query = "note:\"" + modelName + "\""
            guard let ids = try await call("findNotes", ["query": .string(query)]).array else {
                throw controller.invalid()
            }
            for value in ids {
                guard let id = value.integer, let remote = try await controller.note(id, connection: scope.connection)
                else { throw controller.invalid() }
                try await check()
                guard remote.model == modelName,
                    let identity = remote.fields["LingroveNoteID"].flatMap(UUID.init(uuidString:))
                else { continue }
                let key = keyPrefix + identity.uuidString
                var note = journal.notes[key] ?? .init()
                note.id = id
                note.typeID = type.id
                var record = Record(id: id, key: key, value: note)
                try await synchronizeSuspension(material: material, admission: .init(type: type, order: order, resume: resume),
                    record: &record, journal: &journal, call: call)
            }
        }
        func execute(_ plan: NoteAnkiJournal.Plan) async throws {
            let current = try await remoteShape()
            // A lost response can leave any committed prefix. Choose the furthest matching
            // shape; an unrelated Anki edit matches neither the baseline nor a planned stage.
            let completed = plan.steps.lastIndex { $0.after == current }.map { $0 + 1 } ?? 0
            guard completed > 0 || current == plan.before else {
                throw AnkiReviewError.message(
                    String(localized: "This template was customized. Manage it in Anki.", table: "Vocabulary"))
            }
            let previousAdmission = journal.models[modelKey]?.type?.templates.map {
                $0.id.uuidString + String($0.enabled)
            }.sorted()
            let nextAdmission = plan.type.templates.map { $0.id.uuidString + String($0.enabled) }.sorted()
            if previousAdmission != nextAdmission {
                reconcileAllNotes = true
                // Pause all owned siblings BEFORE blanking a shared template. If a call fails,
                // no other note is left with an active empty question. Enabling is reversed:
                // install the readable template first, then release only our own suspensions.
                if let current {
                    try await reconcileModel(
                        plan.type, order: current.order.compactMap(UUID.init(uuidString:)), resume: false)
                }
            }
            for step in plan.steps.dropFirst(completed) {
                _ = try await call(step.action, step.parameters)
                guard try await remoteShape() == step.after else { throw controller.invalid() }
            }
            let oldType = journal.models[modelKey]?.type
            let renames = Dictionary(
                uniqueKeysWithValues: plan.type.fields.compactMap { field -> (String, String)? in
                    guard let old = oldType?.fields.first(where: { $0.id == field.id }), old.name != field.name else {
                        return nil
                    }
                    return (old.name, field.name)
                })
            func remap(_ fields: [String: String]) -> [String: String] {
                Dictionary(uniqueKeysWithValues: fields.map { (renames[$0.key] ?? $0.key, $0.value) })
            }
            for key in Array(journal.notes.keys)
            where key.hasPrefix(keyPrefix) && journal.notes[key]?.typeID == plan.type.id {
                var note = journal.notes[key]!
                note.localFields = remap(note.localFields)
                note.remoteFields = remap(note.remoteFields)
                note.overrides = remap(note.overrides)
                note.pendingFields = note.pendingFields.map(remap)
                note.pendingLocalFields = note.pendingLocalFields.map(remap)
                journal.notes[key] = note
            }
            let shape = plan.steps.last?.after ?? plan.before
            journal.models[modelKey] = .init(
                type: plan.type, shape: shape,
                pending: nil, templateOrder: shape?.order.compactMap(UUID.init(uuidString:)) ?? [])
            try await io.save(journal, material: material)
        }
        if let pending = journal.models[modelKey]?.pending { try await execute(pending) }
        let plan = try NoteAnkiModelPlan.make(
            type: material.type, export: material.export, name: modelName,
            previous: journal.models[modelKey])
        if !plan.steps.isEmpty || journal.models[modelKey]?.type != material.type {
            let old = journal.models[modelKey]
            journal.models[modelKey] = .init(
                type: old?.type, shape: old?.shape, pending: plan,
                templateOrder: old?.templateOrder ?? [])
            try await io.save(journal, material: material)
            try await execute(plan)
        } else {
            guard try await remoteShape() == plan.before else {
                throw AnkiReviewError.message(
                    String(localized: "This template was customized. Manage it in Anki.", table: "Vocabulary"))
            }
        }
        var receipt = journal.notes[noteKey] ?? .init()
        let identity = material.note.id.uuidString.lowercased()
        let matches = try await call("findNotes", ["query": .string("LingroveNoteID:" + identity)])
        guard let ids = matches.array, ids.count <= 1 else { throw controller.invalid() }
        var remote: AnkiRemoteNote?
        if let id = ids.first?.integer {
            remote = try await controller.note(id, connection: scope.connection)
            try await check()
            guard remote?.model == modelName, remote?.fields["LingroveNoteID"] == identity,
                receipt.id == nil || receipt.id == id
            else { throw controller.invalid() }
            receipt.id = id
        } else if receipt.id != nil {
            throw AnkiReviewError.message(
                String(localized: "The associated Anki note no longer exists.", table: "Vocabulary"))
        }
        if let pending = receipt.pendingFields, let remote,
            pending.allSatisfy({ remote.fields[$0.key] == $0.value }) {
            receipt.remoteFields = pending
            receipt.localFields = receipt.pendingLocalFields ?? receipt.localFields
            receipt.pendingFields = nil
            receipt.pendingLocalFields = nil
        }
        if let remote, !choices.isEmpty {
            let changed = choices.keys.filter { expectedRemote[$0] != remote.fields[$0] }
            if !changed.isEmpty { return .init(noteID: receipt.id, conflicts: Array(changed), remote: remote.fields) }
        }
        let merge = remote.map {
            NoteAnkiFieldMerge.resolve(
                desired: material.export.fields, remote: $0.fields,
                receipt: receipt.localFields.isEmpty ? nil : receipt, choices: choices)
        }
        if let merge, !merge.conflicts.isEmpty {
            return .init(noteID: receipt.id, conflicts: merge.conflicts, remote: remote?.fields ?? [:])
        }
        let fields = merge?.fields ?? material.export.fields
        // Persist source/remote intent before add/update. Retrying an unacknowledged create
        // searches the same leading identity field; Anki's duplicate guard closes the race.
        receipt.typeID = material.type.id
        receipt.pendingLocalFields = material.export.fields
        receipt.pendingFields = fields
        receipt.overrides = merge?.overrides ?? [:]
        journal.notes[noteKey] = receipt
        try await io.save(journal, material: material)
        for image in Set(material.referencedImages) {
            let data = try await io.image(image, material: material)
            guard
                try await call(
                    "storeMediaFile",
                    ["filename": .string(image.filename), "data": .string(data.base64EncodedString())]
                ).string == image.filename
            else { throw controller.invalid() }
        }
        let id: Int64
        if let existing = remote {
            id = existing.id
            // Media upload can take time. Re-read the exact note immediately before writing
            // so an Anki edit during that wait returns to conflict resolution instead of loss.
            guard let latest = try await controller.note(id, connection: scope.connection), latest.model == modelName,
                latest.fields["LingroveNoteID"] == identity
            else { throw controller.invalid() }
            try await check()
            let changed = fields.keys.filter {
                latest.fields[$0] != existing.fields[$0] && latest.fields[$0] != fields[$0]
            }
            if !changed.isEmpty { return .init(noteID: id, conflicts: Array(changed), remote: latest.fields) }
            if !fields.allSatisfy({ existing.fields[$0.key] == $0.value }) {
                _ = try await call(
                    "updateNoteFields", ["note": .object(["id": .number(Double(id)), "fields": .strings(fields)])])
            }
        } else {
            guard
                let created = try await call(
                    "addNote",
                    [
                        "note": .object([
                            "deckName": .string(deck),
                            "modelName": .string(modelName), "fields": .strings(fields),
                            "tags": .list(material.sense.tags),
                            "options": .object(["allowDuplicate": .bool(false)])
                        ])
                    ]
                ).integer
            else { throw controller.invalid() }
            id = created
        }
        try await check()
        guard let verified = try await controller.note(id, connection: scope.connection),
            verified.model == modelName, fields.allSatisfy({ verified.fields[$0.key] == $0.value })
        else { throw controller.invalid() }
        try await check()
        receipt.id = id
        receipt.remoteFields = fields
        receipt.localFields = material.export.fields
        receipt.pendingFields = nil
        receipt.pendingLocalFields = nil
        journal.notes[noteKey] = receipt
        try await io.save(journal, material: material)
        if remote != nil && moveExisting {
            guard let ids = try await call("findCards", ["query": .string("nid:" + String(id))]).array else {
                throw controller.invalid()
            }
            _ = try await call("changeDeck", ["cards": .array(ids), "deck": .string(deck)])
        }
        let order = journal.models[modelKey]!.templateOrder
        if reconcileAllNotes {
            try await reconcileModel(material.type, order: order, resume: true)
        } else {
            var record = Record(id: id, key: noteKey, value: receipt)
            try await synchronizeSuspension(material: material, admission: .init(type: material.type, order: order, resume: true),
                record: &record, journal: &journal, call: call)
        }
        return .init(noteID: id, conflicts: [], remote: fields)
    }

    /// Suspending an explicitly disabled template preserves Anki's Card IDs/schedules. Only
    /// suspensions recorded by this adapter can be reversed; pre-existing manual suspensions stay.
    private func synchronizeSuspension(
        material: NoteAnkiIO.Material, admission: Admission,
        record: inout Record, journal: inout NoteAnkiJournal,
        call: (String, [String: AnkiValue]) async throws -> AnkiValue
    ) async throws {
        let id = record.id, noteKey = record.key
        let type = admission.type, order = admission.order, resume = admission.resume
        var receipt = record.value
        defer { record.value = receipt }
        let cards = try await call("findCards", ["query": .string("nid:" + String(id))])
        guard let ids = cards.array, let info = try await call("cardsInfo", ["cards": .array(ids)]).array else {
            throw controller.invalid()
        }
        for value in info {
            guard let row = value.object, let cardID = row["cardId"]?.integer,
                case .number(let ordinal)? = row["ord"], ordinal >= 0, ordinal.rounded() == ordinal,
                ordinal < Double(order.count)
            else { throw controller.invalid() }
            let templateID = order[Int(ordinal)]
            let enabled = type.templates.first(where: { $0.id == templateID })?.enabled == true
            guard
                let suspended = try await call("areSuspended", ["cards": .array([.number(Double(cardID))])]).array?
                    .first,
                case .bool(let isSuspended) = suspended
            else { throw controller.invalid() }
            if !enabled && !isSuspended {
                receipt.suspendedCards.insert(cardID)
                journal.notes[noteKey] = receipt
                try await io.save(journal, material: material)
                _ = try await call("suspend", ["cards": .array([.number(Double(cardID))])])
            } else if resume && enabled && receipt.suspendedCards.contains(cardID) {
                if isSuspended { _ = try await call("unsuspend", ["cards": .array([.number(Double(cardID))])]) }
                receipt.suspendedCards.remove(cardID)
                journal.notes[noteKey] = receipt
                try await io.save(journal, material: material)
            }
        }
    }
}
