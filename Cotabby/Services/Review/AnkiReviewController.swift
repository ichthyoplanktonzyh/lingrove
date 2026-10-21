import AppKit
import Combine
import Foundation
import Logging

/// The composition root retains one controller. It coordinates the shared settings, notebook
/// transactions and injected transport; windows borrow it and never create an HTTP client.
/// One explicit operation at a time prevents two sheets from racing to create the same note.
@MainActor
final class AnkiReviewController: ObservableObject {
    let settings: AnkiReviewSettings
    let store: VocabularyStore
    let client: any AnkiConnecting
    let speech: (any SpeechExporting)?
    let activateAnki: () -> Void
    @Published private(set) var catalog: AnkiReviewCatalog?
    @Published private(set) var connectionMessage: String?
    @Published private(set) var testing = false
    @Published private(set) var sendingReviewID: UUID?
    @Published private(set) var sendingSenseID: UUID?
    @Published private(set) var modelFields: [String] = []
    @Published private(set) var failures: [UUID: String] = [:]
    @Published private(set) var missing: Set<UUID> = []
    @Published private(set) var unresolved: Set<UUID> = []
    var updatingTemplate = false
    var configure: (() -> Void)?

    init(settings: AnkiReviewSettings, store: VocabularyStore, client: any AnkiConnecting = AnkiConnectClient(),
         speech: (any SpeechExporting)? = nil, activateAnki: @escaping () -> Void = {
             NSRunningApplication.runningApplications(withBundleIdentifier: "net.ankiweb.dtop").first?.activate(options: [])
         }) {
        self.settings = settings; self.store = store; self.client = client
        self.speech = speech; self.activateAnki = activateAnki
    }

    func testConnection(model selectedModel: String? = nil) async {
        guard !testing else { return }
        testing = true; connectionMessage = nil
        defer { testing = false }
        do {
            let connection = try settings.connection()
            let model = selectedModel ?? settings.model
            let next = try await fetchCatalog(connection)
            let available = try await fields(for: model, connection: connection, create: false)
            guard try settings.connection() == connection, selectedModel != nil || model == settings.model else { return }
            catalog = next
            modelFields = available
            connectionMessage = String(localized: "Connected", table: "Vocabulary")
            CotabbyLogger.learning.info("Anki connection verified")
        } catch {
            catalog = nil; modelFields = []; connectionMessage = error.localizedDescription
            CotabbyLogger.learning.error("Anki connection failed")
        }
    }

    func refreshFields() async {
        do {
            let model = settings.model, connection = try settings.connection()
            let result = try await fields(for: model, connection: connection, create: false)
            guard model == settings.model, try settings.connection() == connection else { return }
            modelFields = result
        } catch { modelFields = []; connectionMessage = error.localizedDescription }
    }

    func operationScope() async throws -> ReviewOperationScope {
        let connection = try settings.connection(), model = settings.model, mapping = settings.effectiveMapping
        let speechID = speech?.exportConfigurationID
        let deck = settings.deck, hadSavedDeck = settings.hasSavedDeck
        let recognition = settings.defaultRecognition, gap = settings.defaultGap
        let profile = try await profile(connection)
        let value = ReviewOperationScope(connection: connection, profile: profile, model: model, mapping: mapping,
            speechID: speechID, defaultDeck: deck, hadSavedDeck: hadSavedDeck,
            defaultRecognition: recognition, defaultGap: gap)
        guard matches(value) else { throw VocabularyError.editConflict }
        return value
    }
    func matches(_ scope: ReviewOperationScope) -> Bool {
        (try? settings.connection()) == scope.connection && settings.model == scope.model &&
            settings.effectiveMapping == scope.mapping && speech?.exportConfigurationID == scope.speechID
    }
    func verify(_ scope: ReviewOperationScope) async throws {
        guard matches(scope), try await profile(scope.connection) == scope.profile, matches(scope) else {
            throw VocabularyError.editConflict
        }
    }

    func invalidateConnection() { catalog = nil; modelFields = []; connectionMessage = nil }

    func current(entryID: UUID, senseID: UUID) throws -> (entry: VocabularyEntry, sense: VocabularySense) {
        guard let entry = store.entries.first(where: { $0.id == entryID }),
              let sense = entry.senses.first(where: { $0.id == senseID }) else { throw VocabularyError.editConflict }
        return (entry, sense)
    }

    func status(_ entry: VocabularyEntry, _ sense: VocabularySense, cardID: UUID? = nil) -> String {
        let key = cardID ?? sense.id
        if sendingReviewID == key { return String(localized: "Sending…", table: "Vocabulary") }
        if failures[key] != nil { return String(localized: "Send failed", table: "Vocabulary") }
        if unresolved.contains(key) { return String(localized: "Anki fields changed", table: "Vocabulary") }
        if missing.contains(key) { return String(localized: "Anki note missing", table: "Vocabulary") }
        guard let review = sense.reviewValue(cardID) else { return String(localized: "Not added", table: "Vocabulary") }
        if review.needsBindingChoice { return String(localized: "Choose an Anki association", table: "Vocabulary") }
        guard let binding = review.activeBinding else { return String(localized: "Not added", table: "Vocabulary") }
        if binding.noteID == nil { return String(localized: "Ready to send", table: "Vocabulary") }
        guard let content = try? ReviewCardPolicy.content(entry: entry, sense: sense, plan: review.plan),
              let fields = try? AnkiReviewPolicy.fields(content: content, identity: binding.originSenseID,
                mapping: binding.mapping, overrides: review.plan.fieldOverrides, audio: AnkiReviewPolicy.audioFields(review.plan)) else {
            return String(localized: "Review content needs attention", table: "Vocabulary")
        }
        guard AnkiReviewPolicy.currentAudio(review.plan, content: content) else {
            return String(localized: "Update available", table: "Vocabulary")
        }
        return fields == binding.fields ? String(localized: "Synced", table: "Vocabulary")
            : String(localized: "Update available", table: "Vocabulary")
    }

    func isSynchronized(_ entry: VocabularyEntry, _ sense: VocabularySense, cardID: UUID? = nil) -> Bool {
        let key = cardID ?? sense.id
        guard !unresolved.contains(key), !missing.contains(key), failures[key] == nil, let review = sense.reviewValue(cardID),
              let binding = review.activeBinding, binding.noteID != nil,
              let content = try? ReviewCardPolicy.content(entry: entry, sense: sense, plan: review.plan),
              AnkiReviewPolicy.currentAudio(review.plan, content: content),
              let fields = try? AnkiReviewPolicy.fields(content: content, identity: binding.originSenseID,
                mapping: binding.mapping, overrides: review.plan.fieldOverrides, audio: AnkiReviewPolicy.audioFields(review.plan))
        else { return false }
        return fields == binding.fields
    }

    func open(_ binding: AnkiNoteBinding) async -> String? {
        do {
            let connection = try settings.connection()
            try await verifyScope(binding, connection: connection)
            guard let id = binding.noteID else { return nil }
            guard let remote = try await note(id, connection: connection) else {
                throw AnkiReviewError.message(String(localized: "The associated Anki note no longer exists.", table: "Vocabulary"))
            }
            guard remote.fields[binding.identityField] == binding.originSenseID.uuidString.lowercased() else {
                throw AnkiReviewError.message(String(localized: "The Anki note identity changed. Check its association.",
                    table: "Vocabulary"))
            }
            _ = try await call("guiBrowse", ["query": .string("nid:\(id)")], connection)
            return nil
        } catch { return error.localizedDescription }
    }

    func fetchCatalog(_ connection: AnkiConnection) async throws -> AnkiReviewCatalog {
        let profile = try await profile(connection)
        let decks = try strings(await call("deckNames", [:], connection))
        let models = try strings(await call("modelNames", [:], connection))
        return .init(profile: profile, decks: decks, models: models)
    }

    func profile(_ connection: AnkiConnection) async throws -> String {
        guard let name = try await call("getActiveProfile", [:], connection).string, !name.isEmpty else { throw invalid() }
        return name
    }

    func verifyScope(_ binding: AnkiNoteBinding, connection: AnkiConnection) async throws {
        guard binding.endpoint == connection.endpoint.absoluteString, try await profile(connection) == binding.profile else {
            throw AnkiReviewError.message(String(localized: "Switch to the Anki profile associated with this sense.", table: "Vocabulary"))
        }
    }

    func fields(for model: String, connection: AnkiConnection, create: Bool, expectedProfile: String? = nil) async throws -> [String] {
        if model == ReviewLayoutPolicy.model {
            let names = try strings(await call("modelNames", [:], connection))
            if !names.contains(model) {
                guard create else { return ["LingroveID", "Front", "Back"] }
                if let expectedProfile {
                    guard try settings.connection() == connection, try await profile(connection) == expectedProfile else {
                        throw VocabularyError.editConflict
                    }
                }
                _ = try await call("createModel", ["modelName": .string(model),
                    "inOrderFields": .list(["LingroveID", "Front", "Back"]), "css": .string(ReviewLayoutPolicy.css),
                    "isCloze": .bool(false), "cardTemplates": .array([.object([
                        "Name": .string("Card"), "Front": .string("{{Front}}"), "Back": .string("{{Back}}")])])], connection)
            }
        }
        if model == AnkiReviewPolicy.presetName {
            let names = try strings(await call("modelNames", [:], connection))
            if !names.contains(model) {
                guard create else { return ReviewField.allCases.map(\.rawValue) }
                let template: (String, String, String) -> AnkiValue = { name, front, back in
                    .object(["Name": .string(name), "Front": .string(front), "Back": .string(back)])
                }
                if let expectedProfile {
                    guard try settings.connection() == connection, try await profile(connection) == expectedProfile else {
                        throw VocabularyError.editConflict
                    }
                }
                _ = try await call("createModel", ["modelName": .string(model),
                    "inOrderFields": .list(ReviewField.allCases.map(\.rawValue)), "css": .string(AnkiNoteTemplate.css),
                    "isCloze": .bool(false), "cardTemplates": .array([
                        template("Recognition", AnkiNoteTemplate.recognitionFront, AnkiNoteTemplate.recognitionBack),
                        template("Gap", AnkiNoteTemplate.gapFront, AnkiNoteTemplate.gapBack)])], connection)
            }
        }
        return try strings(await call("modelFieldNames", ["modelName": .string(model)], connection))
    }

    func note(_ id: Int64, connection: AnkiConnection) async throws -> AnkiRemoteNote? {
        let result = try await call("notesInfo", ["notes": .array([.number(Double(id))])], connection)
        guard let rows = result.array, rows.count == 1, let row = rows[0].object else { throw invalid() }
        if row.isEmpty { return nil }
        guard row["noteId"]?.integer == id, let model = row["modelName"]?.string,
              let raw = row["fields"]?.object else { throw invalid() }
        var fields: [String: String] = [:]
        for (name, field) in raw {
            guard let text = field.object?["value"]?.string else { throw invalid() }
            fields[name] = text
        }
        return .init(id: id, model: model, fields: fields)
    }

    func call(_ action: String, _ params: [String: AnkiValue], _ connection: AnkiConnection) async throws -> AnkiValue {
        try Task.checkCancellation()
        return try await client.perform(action, params: params, connection: connection)
    }
    func strings(_ value: AnkiValue) throws -> [String] {
        guard let array = value.array, array.allSatisfy({ $0.string != nil }) else { throw invalid() }
        return array.compactMap(\.string)
    }
    func invalid() -> AnkiReviewError { .message(String(localized: "AnkiConnect returned an invalid response.", table: "Vocabulary")) }

    /// Session-owned orchestration borrows this short operation lease. It is acquired before
    /// the first await, and release cannot clear another operation's state.
    func begin(_ id: UUID, cardID: UUID? = nil) throws {
        guard sendingSenseID == nil, !updatingTemplate else {
            throw AnkiReviewError.message(String(localized: "Wait for the current Anki operation to finish.", table: "Vocabulary"))
        }
        let key = cardID ?? id
        sendingSenseID = id; sendingReviewID = key; failures[key] = nil
    }
    func finish(_ id: UUID, cardID: UUID? = nil, error: Error? = nil, missingNote: Bool = false, wrote: Bool = true) {
        let key = cardID ?? id
        if sendingReviewID == key { sendingSenseID = nil; sendingReviewID = nil }
        let cancelled = error is CancellationError
        failures[key] = cancelled ? nil : error?.localizedDescription
        if error == nil && !wrote { unresolved.insert(key) } else if error == nil { unresolved.remove(key) }
        if missingNote { missing.insert(key) } else if error == nil { missing.remove(key) }
        CotabbyLogger.learning.info("Anki operation finished", metadata: ["success": .stringConvertible(error == nil && wrote),
            "cancelled": .stringConvertible(cancelled)])
    }
}
