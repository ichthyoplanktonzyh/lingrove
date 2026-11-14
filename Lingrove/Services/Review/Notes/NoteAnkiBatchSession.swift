import Combine
import Foundation
import LingroveNotebook

/// The batch sheet owns this serial, cancellable send queue. It freezes repository lifetime
/// and connection/profile for a run; each item uses the same Note sender as the individual sheet.
/// Successful sends stay complete on retry because cancellation cannot undo an Anki commit.
@MainActor
final class NoteAnkiBatchSession: ObservableObject {
    enum Status { case ready, sending, synced, failed, cancelled, attention, unavailable }
    struct Item: Identifiable {
        let id = UUID()
        let selection: VocabularySelection
        let expression: String
        let meaning: String
        var status = Status.ready
        var message: String?
    }

    let controller: AnkiReviewController
    private let notebookScope: VocabularyOperationScope?
    @Published private(set) var items: [Item]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    var work: Task<Void, Never>?
    var deckOverride = ""

    init(controller: AnkiReviewController, selections: [VocabularySelection]) {
        self.controller = controller
        notebookScope = controller.store.operationScope
        var seen: Set<VocabularySelection> = []
        items = selections.filter { seen.insert($0).inserted }.map { selection in
            let source = try? controller.current(entryID: selection.entryID, senseID: selection.senseID)
            return .init(selection: selection, expression: source?.entry.expression ?? "",
                meaning: source?.sense.displayTitle ?? "")
        }
    }

    var completeCount: Int { items.filter { $0.status == .synced }.count }
    func noteSent(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .synced
        items[index].message = nil
    }
    func start(only id: UUID? = nil) {
        guard !busy else { return }
        busy = true
        work = Task { [weak self] in await self?.run(only: id) }
    }
    func stop() { work?.cancel() }

    private func run(only id: UUID?) async {
        defer { busy = false; work = nil }
        message = nil
        do {
            guard controller.store.matches(notebookScope), let io = controller.noteIO,
                  let saved = controller.store.completeSnapshot else { throw VocabularyError.editConflict }
            let scope = try await controller.operationScope()
            let (_, type) = try await io.types(scope: saved)
            let decks = try controller.strings(await controller.call("deckNames", [:], scope.connection))
            let deck = deckOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultDeck = decks.contains(scope.defaultDeck) ? scope.defaultDeck : decks.first ?? scope.defaultDeck
            try await controller.verify(scope)
            for index in items.indices {
                if let id, items[index].id != id { continue }
                if items[index].status == .synced { continue }
                try Task.checkCancellation()
                guard controller.store.matches(notebookScope) else { throw VocabularyError.editConflict }
                let selection = items[index].selection
                guard (try? controller.current(entryID: selection.entryID, senseID: selection.senseID)) != nil else {
                    items[index].status = .unavailable
                    continue
                }
                items[index].status = .sending
                items[index].message = nil
                try await send(index, type: type, scope: scope, deck: deck, defaultDeck: defaultDeck)
            }
        } catch {
            message = error is CancellationError ? nil : error.localizedDescription
            for index in items.indices where items[index].status == .sending || items[index].status == .ready {
                items[index].status = error is CancellationError ? .cancelled : .failed
                items[index].message = message
            }
        }
    }

    /// A single item retains the individual sheet's source and remote conflict checks. Keep
    /// this ordered operation separate from queue progress and retry selection above.
    private func send(_ index: Int, type: ReviewNoteType, scope: ReviewOperationScope,
                      deck: String, defaultDeck: String) async throws {
        let session = NoteAnkiSession(controller: controller, selection: items[index].selection)
        await session.load()
        guard session.types.contains(type) else { throw VocabularyError.editConflict }
        if session.material?.type != type {
            session.typeID = type.id
            await session.preview()
        }
        if !deck.isEmpty { session.deck = deck } else if !session.hasAssociation { session.deck = defaultDeck }
        let success = await session.send(expectedScope: scope)
        items[index].status = success ? .synced
            : Task.isCancelled ? .cancelled : session.conflicts.isEmpty ? .failed : .attention
        items[index].message = success ? nil : session.message ?? String(
            localized: "Resolve this item's Anki field changes in preparation.", table: "Vocabulary")
    }

}
