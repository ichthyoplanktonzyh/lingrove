import Combine
import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// One send sheet owns the selected shared type, preview and conflict decisions. Loading is
/// read-only; an explicit send prepares the Note without enrolling it into built-in review.
@MainActor
final class NoteAnkiSession: ObservableObject {
    let controller: AnkiReviewController
    let selection: VocabularySelection
    let scope: VocabularyOperationScope?
    @Published var typeID: UUID?
    @Published var deck: String
    @Published var types: [ReviewNoteType] = []
    @Published var catalog: AnkiReviewCatalog?
    @Published var material: NoteAnkiIO.Material?
    @Published var images: [String: Data] = [:]
    @Published var hasAssociation = false
    @Published var busy = false
    @Published var message: String?
    @Published var conflicts: [AnkiFieldConflict] = []
    @Published var choices: [String: Bool] = [:]
    private var operationScope: ReviewOperationScope?
    private var remoteFields: [String: String] = [:]
    private var startingDeck = ""
    private var loadID = UUID()
    init(controller: AnkiReviewController, selection: VocabularySelection) {
        self.controller = controller
        self.selection = selection
        scope = controller.store.operationScope
        deck = controller.settings.deck
    }
    func load() async {
        guard let scope, let io = controller.noteIO else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let values = try await io.types(scope: scope)
            types = values.0
            let operation = try await controller.operationScope()
            catalog = try await controller.fetchCatalog(operation.connection)
            try await controller.verify(operation)
            guard catalog?.profile == operation.profile else { throw VocabularyError.editConflict }
            operationScope = operation
            if catalog?.decks.contains(deck) == false { deck = catalog?.decks.first ?? deck }
            typeID = values.1.id
            await preview()
        } catch { if !(error is CancellationError) { message = error.localizedDescription } }
    }
    func preview() async {
        let request = UUID()
        loadID = request
        guard let scope, let io = controller.noteIO, let type = types.first(where: { $0.id == typeID }) else { return }
        material = nil
        images = [:]
        conflicts = []
        choices = [:]
        remoteFields = [:]
        do {
            let next = try await io.material(selection: selection, type: type, scope: scope)
            guard loadID == request, !Task.isCancelled else { return }
            material = next
            if let operationScope {
                let key =
                    scope.workspaceId + "|" + operationScope.connection.endpoint.absoluteString + "|"
                    + operationScope.profile + "|" + next.note.id.uuidString
                let receipt = try await io.journal().notes[key]
                hasAssociation = receipt?.id != nil
                if let id = receipt?.id {
                    try await controller.verify(operationScope)
                    let cards = try await controller.call(
                        "findCards", ["query": .string("nid:" + String(id))], operationScope.connection)
                    let info = try await controller.call("cardsInfo", ["cards": cards], operationScope.connection)
                    try await controller.verify(operationScope)
                    guard loadID == request, !Task.isCancelled else { return }
                    if let current = info.array?.first?.object?["deckName"]?.string { deck = current }
                }
                startingDeck = deck
            }
            for reference in next.referencedImages {
                let data = try await io.image(reference, material: next)
                guard loadID == request, !Task.isCancelled else { return }
                images[reference.filename] = data
            }
        } catch { if loadID == request, !(error is CancellationError) { message = error.localizedDescription } }
    }
    func send(expectedScope: ReviewOperationScope? = nil) async -> Bool {
        guard !busy, let material, let operationScope = expectedScope ?? operationScope, let io = controller.noteIO
        else { return false }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await controller.verify(operationScope)
            let prepared = try await io.material(
                selection: selection, type: material.type, scope: material.scope, preparing: true)
            controller.noteDidPrepare?()
            let result = try await NoteAnkiSender(controller: controller, io: io).send(
                prepared,
                scope: operationScope, deck: deck, choices: choices, expectedRemote: remoteFields,
                moveExisting: deck != startingDeck)
            remoteFields = result.remote
            conflicts = result.conflicts.map {
                .init(id: $0, local: prepared.export.fields[$0] ?? "", remote: result.remote[$0] ?? "")
            }
            if !conflicts.isEmpty {
                choices = [:]
                return false
            }
            return true
        } catch {
            if !(error is CancellationError) { message = error.localizedDescription }
            return false
        }
    }
}
