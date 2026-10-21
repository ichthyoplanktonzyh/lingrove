import Combine
import Foundation

/// One batch sheet owns a frozen selection and one cancellable, serial task. Every attempt
/// reconstructs the single-sense transaction from durable state. Successful rows are excluded
/// from retry; failures/conflicts don't stop other rows, and cancellation never rolls back Anki.
@MainActor
final class AnkiReviewBatchSession: ObservableObject {
    let controller: AnkiReviewController
    @Published private(set) var items: [ReviewBatchItem]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    var work: Task<Void, Never>?
    private var preparationBaselines: [UUID: (sense: VocabularySense, expression: String)] = [:]

    init(controller: AnkiReviewController, selections: [VocabularySelection]) {
        self.controller = controller
        var seen: Set<VocabularySelection> = []
        items = selections.filter { seen.insert($0).inserted }.map { selection in
            let entry = controller.store.entries.first { $0.id == selection.entryID }
            let sense = entry.flatMap { entry in VocabularySensePolicy.index(selection.senseID, in: entry).map { entry.senses[$0] } }
            var item = ReviewBatchItem(selection: selection, expression: entry?.expression ?? "", meaning: sense?.displayTitle ?? "")
            if let entry, let sense, controller.isSynchronized(entry, sense) {
                item.status = sense.review?.plan.audioKinds?.isEmpty == false ? .verifyAudio : .synced
            }
            return item
        }
    }
    var completeCount: Int { items.filter { $0.status == .synced }.count }
    func resolve(_ item: ReviewBatchItem) -> (VocabularyEntry, VocabularySense)? {
        guard let entry = controller.store.entries.first(where: { $0.id == item.selection.entryID }),
              let index = VocabularySensePolicy.index(item.selection.senseID, in: entry) else { return nil }
        return (entry, entry.senses[index])
    }
    func beginPreparation(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), let (entry, sense) = resolve(item) else { return }
        preparationBaselines[id] = (sense, entry.expression)
    }
    func refresh(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let (entry, sense) = resolve(items[index]) else { return }
        if let before = preparationBaselines.removeValue(forKey: id), before.sense == sense,
           before.expression == entry.expression { return }
        items[index].expression = entry.expression; items[index].meaning = sense.displayTitle
        // Preparation changes a previously sent row deliberately; ordinary retry never does.
        items[index].status = controller.isSynchronized(entry, sense) ? .synced : .ready; items[index].message = nil
    }
    func start(only id: UUID? = nil) {
        guard !busy else { return }
        busy = true
        work = Task { [weak self] in await self?.run(only: id) }
    }
    func stop() { work?.cancel() }

    func startApply(deck: String, cards: Int, audio: Int) {
        guard !busy else { return }
        busy = true
        work = Task { [weak self] in await self?.apply(deck: deck, cards: cards, audio: audio) }
    }
    private func apply(deck: String, cards: Int, audio: Int) async {
        defer { busy = false; work = nil }
        for index in items.indices {
            if Task.isCancelled {
                items[index].status = .cancelled
                continue
            }
            guard let (entry, sense) = resolve(items[index]) else { items[index].status = .unavailable; continue }
            let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense)
            await session.load()
            if Task.isCancelled { items[index].status = .cancelled; continue }
            applyOptions(session, deck: deck, cards: cards, audio: audio)
            if await session.save() { refresh(items[index].id) } else {
                items[index].status = .failed; items[index].message = session.message
            }
        }
    }

    private func applyOptions(_ session: AnkiReviewSession, deck: String, cards: Int, audio: Int) {
            if !deck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, session.binding?.noteID == nil { session.deck = deck }
            if cards > 0 { session.plan.recognition = cards != 2; session.plan.gap = cards != 1 }
            if audio > 0 {
                let kinds: Set<ReviewAudioKind> = switch audio {
                case 2: [.expression]
                case 3: [.sentence]
                case 4: [.expression, .sentence]
                default: []
                }
                session.plan.audioKinds = kinds
            }
    }

    private func run(only id: UUID?) async {
        defer { busy = false; work = nil }
        message = nil
        do {
            let scope = try await controller.operationScope()
            let decks = try controller.strings(await controller.call("deckNames", [:], scope.connection))
            let defaultDeck = !scope.hadSavedDeck && !decks.contains(scope.defaultDeck)
                ? decks.first ?? scope.defaultDeck : scope.defaultDeck
            try await controller.verify(scope)
            var seen = Set(items.filter { $0.status == .synced }.compactMap { item in
                resolve(item).map { VocabularySelection(entryID: $0.0.id, senseID: $0.1.id) }
            })
            for index in items.indices {
                if let id, items[index].id != id { continue }
                if items[index].status == .synced || items[index].status == .skipped { continue }
                try Task.checkCancellation()
                guard let (entry, sense) = resolve(items[index]) else { items[index].status = .unavailable; continue }
                let canonical = VocabularySelection(entryID: entry.id, senseID: sense.id)
                if !seen.insert(canonical).inserted { items[index].status = .skipped; continue }
                try await controller.verify(scope)
                items[index].status = .sending; items[index].message = nil
                let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, defaults: scope)
                // Existing preparations/bindings retain their deck. Unprepared rows share the
                // batch's captured default even if another window edits preferences mid-run.
                if sense.review?.activeBinding == nil, sense.review?.plan.deck == nil { session.deck = defaultDeck }
                await session.load()
                if let issue = session.validationMessage {
                    items[index].status = .attention; items[index].message = issue; continue
                }
                let success = await session.send(expectedScope: scope)
                session.audio.discard()
                if success { items[index].status = .synced } else {
                    items[index].status = Task.isCancelled ? .cancelled : session.conflicts.isEmpty ? .failed : .attention
                    items[index].message = Task.isCancelled ? nil : session.message ?? String(
                        localized: "Resolve this item's Anki field changes in preparation.",
                        table: "Vocabulary")
                }
            }
        } catch {
            message = error is CancellationError ? nil : error.localizedDescription
            for index in items.indices where items[index].status == .sending || items[index].status == .ready ||
                items[index].status == .verifyAudio {
                items[index].status = error is CancellationError ? .cancelled : .failed
                items[index].message = message
            }
        }
    }
}
