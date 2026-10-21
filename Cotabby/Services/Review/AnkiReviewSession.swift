import Combine
import Foundation

/// A sheet owns this draft/session until Save, Send or Cancel. It borrows the process controller
/// and keeps network errors/conflicts local to the preparation UI. Source text is revalidated
/// after suspension points; a verified remote receipt is committed separately from a draft.
@MainActor
final class AnkiReviewSession: ObservableObject {
    let controller: AnkiReviewController
    let entryID: UUID
    let senseID: UUID
    @Published var plan: ReviewPlan
    @Published private(set) var bindingID: UUID? {
        didSet {
            if let binding { deck = binding.deck }
            if model != AnkiReviewPolicy.presetName { plan.recognition = true }
            conflicts = []; keepRemote = [:]; conflictRemote = nil
        }
    }
    @Published var deck: String
    @Published var conflicts: [AnkiFieldConflict] = []
    @Published var keepRemote: [String: Bool] = [:]
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published private(set) var missingNote = false
    @Published private(set) var catalog: AnkiReviewCatalog?
    @Published private(set) var availableFields: [String] = []
    @Published private(set) var loading = false
    private var baseline: VocabularyReview?
    private var conflictRemote: AnkiRemoteNote?
    private var metadataID = UUID()

    init(controller: AnkiReviewController, entry: VocabularyEntry, sense: VocabularySense) {
        self.controller = controller; entryID = entry.id; senseID = sense.id
        baseline = sense.review
        var initial = ReviewCardPolicy.initialPlan(sense)
        if sense.review == nil {
            initial.recognition = controller.settings.defaultRecognition
            initial.gap = controller.settings.defaultGap &&
                sense.examples.first.map { ReviewCardPolicy.gap(in: $0.text, ranges: $0.ranges, kind: entry.kind) != nil } == true
            if !initial.recognition && !initial.gap { initial.recognition = true }
        }
        plan = initial; bindingID = sense.review?.activeBindingID
        deck = sense.review?.activeBinding?.deck ?? initial.deck ?? controller.settings.deck
        if model != AnkiReviewPolicy.presetName { plan.recognition = true }
    }

    var current: (entry: VocabularyEntry, sense: VocabularySense)? { try? controller.current(entryID: entryID, senseID: senseID) }
    var binding: AnkiNoteBinding? { baseline?.bindings.first { $0.id == bindingID } }
    var model: String { binding?.model ?? controller.settings.model }
    var mapping: [ReviewField: String] { binding?.mapping ?? controller.settings.effectiveMapping }
    var content: ReviewCardContent? {
        guard let current else { return nil }
        return try? ReviewCardPolicy.content(entry: current.entry, sense: current.sense, plan: plan)
    }
    var validationMessage: String? {
        guard let current else { return VocabularyError.editConflict.localizedDescription }
        do {
            if let binding, AnkiReviewPolicy.removesExistingCard(plan, binding: binding) {
                return String(localized: "Manage existing card types in Anki.", table: "Vocabulary")
            }
            if baseline?.needsBindingChoice == true && bindingID == nil || deck.isEmpty ||
                binding?.noteID == nil && catalog.map({ !$0.decks.contains(deck) }) == true {
                return String(localized: "Choose a deck and an Anki association.", table: "Vocabulary")
            }
            let content = try ReviewCardPolicy.content(entry: current.entry, sense: current.sense, plan: plan)
            let fields = try AnkiReviewPolicy.fields(content: content, identity: binding?.originSenseID ?? senseID,
                mapping: mapping, overrides: plan.fieldOverrides)
            if !availableFields.isEmpty && !fields.keys.allSatisfy({ availableFields.contains($0) }) {
                return String(localized: "The Anki note type does not contain the mapped fields.", table: "Vocabulary")
            }
            return nil
        } catch { return error.localizedDescription }
    }
    var answer: String {
        if let answer = plan.answer { return answer }
        guard let current else { return "" }
        var preview = plan; preview.recognition = true; preview.gap = false
        return (try? ReviewCardPolicy.content(entry: current.entry, sense: current.sense, plan: preview).answer) ?? ""
    }
    var canGap: Bool {
        guard let current, let example = current.sense.examples.first(where: { $0.id == plan.exampleID }) else { return false }
        return ReviewCardPolicy.gap(in: example.text, ranges: example.ranges, kind: current.entry.kind) != nil
    }
    func hasExistingCard(_ field: ReviewField) -> Bool {
        guard let binding, binding.noteID != nil, let name = binding.mapping[field] else { return false }
        return !(binding.fields[name] ?? "").isEmpty
    }

    func selectBinding(_ id: UUID?) { bindingID = id }

    func restorePlan(_ saved: ReviewPlan) {
        var restored = saved; restored.id = UUID()
        if model != AnkiReviewPolicy.presetName { restored.recognition = true }
        plan = restored
        if binding?.noteID == nil, let savedDeck = saved.deck { deck = savedDeck }
    }

    func load() async {
        let request = UUID(), selectedID = bindingID, selectedModel = model
        metadataID = request; loading = true; availableFields = []; message = nil
        defer { if metadataID == request { loading = false } }
        do {
            let connection = try controller.settings.connection()
            let catalog = try await controller.fetchCatalog(connection)
            let fields = try await controller.fields(for: selectedModel, connection: connection, create: false)
            try Task.checkCancellation()
            guard metadataID == request, bindingID == selectedID, model == selectedModel,
                  try controller.settings.connection() == connection else { return }
            self.catalog = catalog; availableFields = fields
            // A translated Anki installation may call its initial deck something other than
            // "Default". Only an untouched default can follow that first available deck.
            if binding == nil, plan.deck == nil, !controller.settings.hasSavedDeck, !catalog.decks.contains(deck),
               let first = catalog.decks.first { deck = first }
        } catch {
            if metadataID == request && !Task.isCancelled { message = error.localizedDescription }
        }
    }

    func save() async -> Bool {
        do { try await savePlan(); return true } catch { message = error.localizedDescription; return false }
    }

    private func savePlan() async throws {
        let current = try controller.current(entryID: entryID, senseID: senseID)
        guard current.sense.review == baseline else { throw VocabularyError.editConflict }
        plan.deck = deck
        var next = baseline ?? VocabularyReview(plan: plan)
        next.plan = plan; next.activeBindingID = bindingID
        if let index = next.bindings.firstIndex(where: { $0.id == bindingID && $0.noteID == nil }) {
            // A pending creation keeps its UUID/profile/model while the user corrects a deck
            // that disappeared. Confirmed notes never move decks as a side effect of an update.
            next.bindings[index].deck = deck
        }
        try await controller.store.saveReview(entryID: entryID, senseID: senseID, value: next, expected: baseline)
        baseline = next
    }

    /// Every retry searches the explicit identity field before creating a note. This recovers
    /// an addNote whose acknowledgement was lost, without trusting expression/first-field text.
    func send(recreateMissing: Bool = false) async -> Bool {
        guard !busy else { return false }
        do { try controller.begin(senseID) } catch { message = error.localizedDescription; return false }
        busy = true; message = nil
        defer { busy = false }
        do {
            let result = try await synchronize(recreateMissing: recreateMissing)
            controller.finish(senseID)
            return result
        } catch {
            message = error.localizedDescription
            controller.finish(senseID, error: error, missingNote: missingNote)
            return false
        }
    }

    private func synchronize(recreateMissing: Bool) async throws -> Bool {
        let source = try controller.current(entryID: entryID, senseID: senseID)
        let content = try ReviewCardPolicy.content(entry: source.entry, sense: source.sense, plan: plan)
        if let binding, AnkiReviewPolicy.removesExistingCard(plan, binding: binding) {
            throw AnkiReviewError.message(String(localized: "Manage existing card types in Anki.", table: "Vocabulary"))
        }
        guard !(baseline?.needsBindingChoice == true && bindingID == nil), !deck.isEmpty else {
            throw AnkiReviewError.message(String(localized: "Choose a deck and an Anki association.", table: "Vocabulary"))
        }
        try await savePlan()
        let connection = try controller.settings.connection()
        let profile = try await controller.profile(connection)
        var existing = binding
        if let existing { try await controller.verifyScope(existing, connection: connection) }
        let identity = existing?.originSenseID ?? senseID
        let model = self.model, mapping = self.mapping
        let available = try await controller.fields(for: model, connection: connection, create: false)
        var desired = try AnkiReviewPolicy.fields(content: content, identity: identity,
            mapping: mapping, overrides: plan.fieldOverrides)
        guard desired.keys.allSatisfy({ available.contains($0) }), let identityField = mapping[.identity] else {
            throw AnkiReviewError.message(String(localized: "The Anki note type does not contain the mapped fields.", table: "Vocabulary"))
        }
        if existing == nil {
            // Persist the remote creation identity before *any* write. An acknowledgement can
            // be lost while the sense is merged or the process exits; the pending binding then
            // travels with that merge, so reopening searches the original UUID, never a new one.
            let intent = AnkiNoteBinding(originSenseID: identity, endpoint: connection.endpoint.absoluteString,
                profile: profile, noteID: nil, model: model, deck: deck, identityField: identityField,
                mapping: mapping, fields: desired, syncedAt: nil)
            try await controller.store.recordAnkiBinding(entryID: entryID, senseID: senseID, binding: intent)
            baseline = try controller.current(entryID: entryID, senseID: senseID).sense.review
            bindingID = intent.id
            existing = intent
        }
        let remote = try await remoteNote(existing: existing, target: (identity, identityField),
            model: model, recreate: recreateMissing, connection: connection)
        if let remote {
            guard remote.model == model, remote.fields[identityField] == identity.uuidString.lowercased() else {
                throw AnkiReviewError.message(String(localized: "The Anki note identity changed. Check its association.",
                    table: "Vocabulary"))
            }
            guard let resolved = try await resolve(remote, existing: existing, desired: desired, identityField: identityField)
            else { return false }
            desired = resolved
        }
        // A draft/source or profile change during connection checks invalidates the operation
        // before writing. Metadata and unrelated dictionary browsing are deliberately excluded.
        try validateCurrent(content, connection: connection)
        guard try await controller.profile(connection) == profile else { throw VocabularyError.editConflict }
        let noteID = try await write(remote, desired: desired, context: (content, profile), connection: connection, model: model)
        guard try await controller.profile(connection) == profile,
              let verified = try await controller.note(noteID, connection: connection), verified.model == model,
              desired.allSatisfy({ verified.fields[$0.key] == $0.value }) else {
            throw AnkiReviewError.message(String(localized: "Anki did not confirm the saved fields. Retry to check the note.",
                table: "Vocabulary"))
        }
        let receipt = AnkiNoteBinding(id: existing?.id ?? UUID(), originSenseID: identity,
            endpoint: connection.endpoint.absoluteString, profile: profile, noteID: noteID, model: model, deck: deck,
            identityField: identityField, mapping: mapping, fields: desired, syncedAt: Date())
        try await controller.store.recordAnkiBinding(entryID: entryID, senseID: senseID, binding: receipt)
        controller.settings.deck = deck
        controller.settings.defaultRecognition = plan.recognition; controller.settings.defaultGap = plan.gap
        missingNote = false; conflicts = []
        return true
    }

    private func write(_ remote: AnkiRemoteNote?, desired: [String: String],
                       context: (content: ReviewCardContent, profile: String), connection: AnkiConnection,
                       model: String) async throws -> Int64 {
        let noteID: Int64
        if let remote {
            noteID = remote.id
            if !desired.allSatisfy({ remote.fields[$0.key] == $0.value }) {
                _ = try await controller.call("updateNoteFields", ["note": .object([
                    "id": .number(Double(noteID)), "fields": .strings(desired)])], connection)
            }
        } else {
            _ = try await controller.fields(for: model, connection: connection, create: true)
            try validateCurrent(context.content, connection: connection)
            guard try await controller.profile(connection) == context.profile else { throw VocabularyError.editConflict }
            let value = try await controller.call("addNote", ["note": .object([
                "deckName": .string(deck), "modelName": .string(model), "fields": .strings(desired),
                "options": .object(["allowDuplicate": .bool(model != AnkiReviewPolicy.presetName)]),
                "tags": .list(["Lingrove"])])], connection)
            guard let id = value.integer else { throw controller.invalid() }
            noteID = id
        }
        return noteID
    }

    private func resolve(_ remote: AnkiRemoteNote, existing: AnkiNoteBinding?, desired: [String: String],
                         identityField: String) async throws -> [String: String]? {
        let changed = AnkiReviewPolicy.conflicts(base: existing?.fields ?? [:], local: desired, remote: remote.fields)
        guard !changed.isEmpty else { return desired }
        guard conflictRemote == remote, changed.allSatisfy({ keepRemote[$0.id] != nil }) else {
            conflicts = changed; keepRemote = [:]; conflictRemote = remote
            return nil
        }
        var result = desired
        for conflict in changed where keepRemote[conflict.id] == true {
            guard conflict.id != identityField else { throw VocabularyError.editConflict }
            plan.fieldOverrides[conflict.id] = conflict.remote
            result[conflict.id] = conflict.remote
        }
        try await savePlan()
        return result
    }

    private func validateCurrent(_ content: ReviewCardContent, connection: AnkiConnection) throws {
        let current = try controller.current(entryID: entryID, senseID: senseID)
        guard current.sense.review == baseline, try controller.settings.connection() == connection,
              try ReviewCardPolicy.content(entry: current.entry, sense: current.sense, plan: plan) == content else {
            throw VocabularyError.editConflict
        }
    }

    private func remoteNote(existing: AnkiNoteBinding?, target: (id: UUID, field: String), model: String,
                            recreate: Bool, connection: AnkiConnection) async throws -> AnkiRemoteNote? {
        let (identity, field) = target
        if let id = existing?.noteID, let remote = try await controller.note(id, connection: connection) { return remote }
        if existing?.noteID != nil && !recreate {
            missingNote = true
            throw AnkiReviewError.message(String(localized: "The associated Anki note no longer exists.", table: "Vocabulary"))
        }
        // Quote the entire search term. Only UUID text is searched, then notesInfo verifies both
        // field equality and model before an existing note can be reused.
        guard !field.contains("\""), !field.contains("\\"), !field.contains(":") else { throw controller.invalid() }
        let query = "\"\(field):\(identity.uuidString.lowercased())\""
        let matches = try await controller.call("findNotes", ["query": .string(query)], connection)
        guard let rows = matches.array, rows.count <= 32, rows.allSatisfy({ $0.integer != nil }) else { throw controller.invalid() }
        var found: [AnkiRemoteNote] = []
        for row in rows {
            if let id = row.integer, let note = try await controller.note(id, connection: connection),
               note.model == model, note.fields[field] == identity.uuidString.lowercased() { found.append(note) }
        }
        guard found.count <= 1 else {
            throw AnkiReviewError.message(String(localized: "Several Anki notes use this sense ID. Resolve duplicates in Anki.",
                table: "Vocabulary"))
        }
        return found.first
    }
}
