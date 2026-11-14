import LingroveNotebook
import AppKit
import Combine
import Foundation
import Logging

/// The composition root retains one controller. It coordinates the shared settings, notebook
/// transactions and injected transport; windows borrow it and never create an HTTP client.
/// One explicit operation at a time prevents two sheets from racing to create the same note.
@MainActor
final class AnkiReviewController: ObservableObject {
    let noteIO: NoteAnkiIO?
    var noteDidPrepare: (() -> Void)?
    let settings: AnkiReviewSettings
    let store: VocabularyStore
    let client: any AnkiConnecting
    let speech: (any SpeechExporting)?
    let activateAnki: () -> Void
    @Published private(set) var catalog: AnkiReviewCatalog?
    @Published private(set) var connectionMessage: String?
    @Published private(set) var testing = false
    private var openingMenuReview = false
    private var sendingNoteID: UUID?
    @Published private(set) var sendingSenseID: UUID?
    var configure: (() -> Void)?

    /// The menu closes before this operation finishes. Keep failure feedback on the shared
    /// controller and reveal its existing settings window, rather than losing an alert with
    /// the popover. A repeated menu click cannot race another Anki navigation operation.
    func openReviewFromMenu() async {
        guard !openingMenuReview else { return }
        openingMenuReview = true
        connectionMessage = nil
        defer { openingMenuReview = false }
        if let message = await reviewDeck() {
            connectionMessage = message
            configure?()
        }
    }

    init(settings: AnkiReviewSettings, store: VocabularyStore, repository: MacNotebookRepository? = nil,
         client: any AnkiConnecting = AnkiConnectClient(),
         speech: (any SpeechExporting)? = nil, activateAnki: @escaping () -> Void = {
             NSRunningApplication.runningApplications(withBundleIdentifier: "net.ankiweb.dtop").first?.activate(options: [])
         }) {
        noteIO = repository.map { NoteAnkiIO(repository: $0) }
        noteDidPrepare = { [weak repository] in repository?.publishChange() }
        self.settings = settings; self.store = store; self.client = client
        self.speech = speech; self.activateAnki = activateAnki

    }

    func testConnection() async {
        guard !testing else { return }
        testing = true; connectionMessage = nil
        defer { testing = false }
        do {
            let connection = try settings.connection()
            let next = try await fetchCatalog(connection)
            guard try settings.connection() == connection else { return }
            catalog = next
            connectionMessage = String(localized: "Connected", table: "Vocabulary")
            LingroveLogger.learning.info("Anki connection verified")
        } catch {
            catalog = nil; connectionMessage = error.localizedDescription
            LingroveLogger.learning.error("Anki connection failed")
        }
    }

    func operationScope() async throws -> ReviewOperationScope {
        let notebookScope = store.operationScope
        let connection = try settings.connection(), deck = settings.deck
        let profile = try await profile(connection)
        let value = ReviewOperationScope(notebookScope: notebookScope, connection: connection,
            profile: profile, defaultDeck: deck)
        guard matches(value) else { throw VocabularyError.editConflict }
        return value
    }
    func matches(_ scope: ReviewOperationScope) -> Bool {
        store.matches(scope.notebookScope) && (try? settings.connection()) == scope.connection
    }
    func verify(_ scope: ReviewOperationScope) async throws {
        guard matches(scope), try await profile(scope.connection) == scope.profile, matches(scope) else {
            throw VocabularyError.editConflict
        }
    }

    func invalidateConnection() { catalog = nil; connectionMessage = nil }

    func current(entryID: UUID, senseID: UUID) throws -> (entry: VocabularyEntry, sense: VocabularySense) {
        guard let entry = store.entries.first(where: { $0.id == entryID }),
              let sense = entry.senses.first(where: { $0.id == senseID }) else { throw VocabularyError.editConflict }
        return (entry, sense)
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
    func begin(_ senseID: UUID, noteID: UUID) throws {
        guard sendingSenseID == nil else {
            throw AnkiReviewError.message(String(localized: "Wait for the current Anki operation to finish.", table: "Vocabulary"))
        }
        sendingSenseID = senseID
        sendingNoteID = noteID
    }

    func finish(_ senseID: UUID, noteID: UUID, error: Error? = nil, wrote: Bool = true,
                scope: VocabularyOperationScope) {
        if sendingSenseID == senseID, sendingNoteID == noteID {
            sendingSenseID = nil
            sendingNoteID = nil
        }
        guard store.matches(scope) else { return }
        LingroveLogger.learning.info("Anki operation finished", metadata: ["success": .stringConvertible(error == nil && wrote),
            "cancelled": .stringConvertible(error is CancellationError)])
    }
}
