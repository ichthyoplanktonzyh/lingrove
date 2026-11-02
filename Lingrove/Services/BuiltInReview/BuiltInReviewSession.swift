import Combine
import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// One reusable native review window owns this MainActor presentation model. The repository
/// owns persistence for the whole app; this model owns only navigation, an unsaved sheet, the
/// pinned question and cancellable IO. Closing it never shuts down corpus, sync or autocomplete.
@MainActor
final class BuiltInReviewSession: ObservableObject {
    // @Published tells the hosted SwiftUI root to redraw; these properties are temporary
    // presentation state. A durable change still requires an explicit shared-engine command.
    @Published private(set) var content: NotebookBuiltInReviewSnapshot?
    @Published var route: BuiltInReviewRoute = .overview
    @Published var draft: BuiltInReviewDraft?
    @Published private(set) var practice: BuiltInReviewPractice?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var message: String?
    @Published private(set) var images: [BuiltInReviewSavedImage] = []
    var onOpenSource: ((VocabularySelection) -> Void)?

    private let repository: MacNotebookRepository
    private let io: BuiltInReviewIO
    let speech: LearningSpeechController?
    private let speechOwnerID = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var lifetime = UUID()
    private var readIdentity = UUID()
    private var writeIdentity = UUID()
    private var isVisible = false
    private var isShuttingDown = false
    private var isPublishing = false

    var isBusy: Bool { isRefreshing || isMutating }
    var canSpeak: Bool { speech != nil }

    init(repository: MacNotebookRepository, speech: LearningSpeechController? = nil) {
        self.repository = repository
        self.speech = speech
        io = BuiltInReviewIO(databaseURL: repository.databaseURL, mediaDirectoryURL: repository.mediaDirectoryURL)
        repository.$changeSequence.dropFirst().sink { [weak self] _ in
            self?.repositoryDidChange()
        }.store(in: &subscriptions)
        speech?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    func open(selection: VocabularySelection?) {
        guard !isShuttingDown else { return }
        close()
        isVisible = true
        route = selection.map(BuiltInReviewRoute.sense) ?? .overview
        reload()
    }

    func close() {
        isVisible = false
        lifetime = UUID()
        writeIdentity = UUID()
        readTask?.cancel()
        // A window can close while explicit Quit awaits the admitted writer. Hide its UI and
        // revoke presentation identity, but keep that writer alive for the app's drain owner.
        if !isShuttingDown { writeTask?.cancel(); writeTask = nil }
        imageTask?.cancel()
        readTask = nil
        imageTask = nil
        draft = nil
        practice = nil
        content = nil
        images = []
        message = nil
        isRefreshing = false
        isMutating = false
        stopOwnSpeech()
    }

    func reload(afterOwnChange: Bool = false, preferredCardID: String? = nil) {
        guard isVisible else { return }
        readTask?.cancel()
        let operation = UUID()
        readIdentity = operation
        let savedLifetime = lifetime
        let previous = content
        let scope: LingroveNotebookSnapshot
        do { scope = try repository.snapshot() } catch {
            readTask = nil
            isRefreshing = false
            content = nil
            clearUnsavedSession(cancelWrite: true)
            message = BuiltInReviewCopy.text("error.load")
            return
        }
        if let previous, previous.scope != scope {
            clearUnsavedSession(cancelWrite: true)
            if !sameLifetime(previous.scope, scope) { content = nil; route = .overview }
            message = BuiltInReviewCopy.text("message.changed")
        }
        isRefreshing = true
        readTask = Task { [weak self, io] in
            do {
                let value = try await io.load(scope: scope, now: Date())
                guard let self, self.isVisible, self.lifetime == savedLifetime, self.readIdentity == operation,
                      !Task.isCancelled else { return }
                guard try self.repository.snapshot() == value.scope else {
                    self.isRefreshing = false
                    self.clearUnsavedSession(cancelWrite: true)
                    self.content = nil
                    self.message = BuiltInReviewCopy.text("message.changed")
                    return
                }
                // A successful retry replaces an unavailable read and its old error banner.
                self.message = previous == nil ? nil : self.message
                if let previous, !afterOwnChange, !self.samePresentedData(previous, value) {
                    self.clearUnsavedSession(cancelWrite: true)
                    self.message = BuiltInReviewCopy.text("message.changed")
                }
                self.content = value
                self.isRefreshing = false
                if afterOwnChange, self.practice != nil { self.advancePractice(preferredCardID: preferredCardID) }
            } catch {
                guard let self, self.lifetime == savedLifetime, self.readIdentity == operation, !Task.isCancelled else { return }
                self.isRefreshing = false
                self.content = nil
                self.clearUnsavedSession(cancelWrite: true)
                self.message = BuiltInReviewCopy.text("error.load")
            }
        }
    }

    func prepare(selection: VocabularySelection, additional: Bool = false, basedOn value: NotebookBuiltInReviewSnapshot) {
        guard canAct(in: value.scope) else { return }
        do { draft = try .init(content: value, selection: selection, additional: additional) } catch {
            message = BuiltInReviewCopy.text("error.source")
        }
    }

    func edit(card: Card, link: LingroveNotebookCardLink, selection: VocabularySelection,
              basedOn value: NotebookBuiltInReviewSnapshot) {
        guard canAct(in: value.scope) else { return }
        draft = .init(content: value, card: card, link: link, selection: selection)
    }

    func save(_ value: BuiltInReviewDraft) {
        guard draft?.id == value.id, value.canSave else { return }
        mutate(.save(value), scope: value.snapshot, destination: .sense(value.selection))
    }

    func enrollDefault(selection: VocabularySelection, basedOn value: NotebookBuiltInReviewSnapshot) {
        guard canAct(in: value.scope) else { return }
        do {
            let prepared = try BuiltInReviewDraft(content: value, selection: selection)
            mutate(.save(prepared), scope: value.scope, destination: .sense(selection))
        } catch { message = BuiltInReviewCopy.text("error.source") }
    }

    func setStatus(_ status: LingroveNotebookReviewStatus, selection: VocabularySelection,
                   basedOn value: NotebookBuiltInReviewSnapshot) {
        let action = NotebookBuiltInReviewAction(content: value, selection: selection)
        mutate(.status(status, action, UUID()), scope: value.scope, destination: .sense(selection))
    }

    func retain(_ context: BuiltInReviewCardContext) {
        mutate(.retain(context), scope: context.snapshot, destination: .sense(context.group.selection))
    }

    func start(selection: VocabularySelection? = nil) {
        guard let value = content, canAct(in: value.scope) else { return }
        draft = nil
        message = nil
        practice = .init(selection: selection)
        route = .practice
        advancePractice()
    }

    func reveal() {
        guard !isBusy, case let .question(context) = practice?.phase else { return }
        practice?.phase = .answer(context)
    }

    func rate(_ rating: ReviewRating) {
        guard !isBusy, case let .answer(context) = practice?.phase else { return }
        mutate(.rate(context, rating, Date(), TimeZone.current.identifier), scope: context.snapshot, destination: .practice)
    }

    func undo(_ undo: BuiltInReviewUndoAction) {
        mutate(.undo(undo), scope: undo.action.scope, destination: route, preferredCardID: undo.identity.cardID)
    }

    func endPractice() {
        stopOwnSpeech()
        imageTask?.cancel()
        images = []
        practice = nil
        route = .overview
    }

    func openSource(_ context: BuiltInReviewCardContext) {
        guard let value = content, sameLifetime(value.scope, context.snapshot),
              let selection = LingroveNotebookCardMaterial.resolvedSelection(source: context.link.source, snapshot: value.scope)
        else { message = BuiltInReviewCopy.text("error.source"); return }
        onOpenSource?(selection)
    }

    func speak(_ context: BuiltInReviewCardContext, answer: Bool) {
        let selection = LingroveNotebookCardMaterial.resolvedSelection(source: context.link.source, snapshot: context.snapshot)
        let entry = context.snapshot.document.entries.first { $0.id == selection?.entryID }
        let sense = entry?.senses.first { $0.id == selection?.senseID }
        let text = answer ? context.card.backText : context.card.frontText
        let plain = BuiltInReviewText.plain(text)
        speech?.toggle(.init(target: speechTarget(context, answer: answer), text: plain,
            language: answer ? sense?.meaningLanguage : entry?.language))
    }

    func isSpeaking(_ context: BuiltInReviewCardContext, answer: Bool) -> Bool {
        speech?.isPlaying(speechTarget(context, answer: answer)) == true
    }

    func undoAction(cardID: String, basedOn value: NotebookBuiltInReviewSnapshot) -> BuiltInReviewUndoAction? {
        guard let identity = value.undoByCardID[cardID],
              let group = value.review.groups.values.first(where: { $0.cards.contains { $0.cardId == cardID } }) else { return nil }
        return .init(action: .init(content: value, selection: group.selection), identity: identity)
    }

    var latestUndo: BuiltInReviewUndoAction? {
        guard let value = content else { return nil }
        let cardID = value.recentHistory.first { value.undoByCardID[$0.cardID] != nil }?.cardID
        return cardID.flatMap { undoAction(cardID: $0, basedOn: value) }
    }

    func context(card: Card, group: LingroveNotebookReviewGroup,
                 content value: NotebookBuiltInReviewSnapshot) -> BuiltInReviewCardContext? {
        guard let link = value.review.links.first(where: { $0.cardId == card.cardId && $0.deletedAt == nil }) else { return nil }
        return .init(snapshot: value.scope, card: card, link: link, group: group,
            schedulerSettings: value.schedulerSettings, action: .init(content: value, selection: group.selection))
    }

    /// Tests await the actual task instead of treating an idle spinner or compiled test as an
    /// executed persistence check. Tasks may enqueue the next read after a successful mutation.
    func waitForIdle() async {
        await writeTask?.value
        await readTask?.value
        await imageTask?.value
    }

    /// Unlike Cancel/close, explicit application Quit waits for the already-admitted writer.
    /// The flag prevents another click from enqueuing a second write during this actor await.
    func prepareForShutdown() { isShuttingDown = true }

    func shutdownAfterDraining() async {
        prepareForShutdown()
        await writeTask?.value
        writeTask = nil
        close()
    }

    private func mutate(_ command: BuiltInReviewIO.Command, scope: LingroveNotebookSnapshot,
                        destination: BuiltInReviewRoute, preferredCardID: String? = nil) {
        guard canAct(in: scope) else { return }
        let savedLifetime = lifetime
        let operation = UUID()
        writeIdentity = operation
        message = nil
        isMutating = true
        writeTask = Task { [weak self, io, repository] in
            do {
                try await io.perform(command)
                guard let self else { repository.publishChange(); return }
                // Commit visibility belongs to the repository even if the window closed while
                // IO completed. A late result must not resurrect the closed UI session.
                self.isPublishing = self.lifetime == savedLifetime && self.writeIdentity == operation
                repository.publishChange()
                self.isPublishing = false
                guard self.isVisible, self.lifetime == savedLifetime, self.writeIdentity == operation else { return }
                self.isMutating = false
                self.draft = nil
                self.route = destination
                if case .rate = command { self.practice?.answered += 1 }
                if case .undo = command { self.practice?.answered = max(0, (self.practice?.answered ?? 0) - 1) }
                self.stopOwnSpeech()
                self.reload(afterOwnChange: true, preferredCardID: preferredCardID)
            } catch {
                guard let self, self.isVisible, self.lifetime == savedLifetime, self.writeIdentity == operation else { return }
                self.isMutating = false
                self.clearUnsavedSession()
                self.message = BuiltInReviewCopy.text(error is CancellationError ? "message.changed" : "error.write")
                self.reload()
            }
        }
    }

    private func canAct(in scope: LingroveNotebookSnapshot) -> Bool {
        guard isVisible, !isBusy, !isShuttingDown else { return false }
        guard (try? repository.snapshot()) == scope else {
            clearUnsavedSession(cancelWrite: true)
            message = BuiltInReviewCopy.text("message.changed")
            reload()
            return false
        }
        return true
    }

    private func repositoryDidChange() {
        guard isVisible, !isPublishing else { return }
        // A notification can describe only an upload ACK. Disable actions while re-reading,
        // then discard a draft/question only if its actual scope or review rows changed.
        reload()
    }

    private func advancePractice(preferredCardID: String? = nil) {
        guard let value = content, var practice else { return }
        let cards = value.queue.filter { card in
            guard let selection = practice.selection else { return true }
            return value.review.groups[selection.senseID]?.cards.contains { $0.cardId == card.cardId } == true
        }
        let next = preferredCardID.flatMap { id in cards.first { $0.cardId == id } } ?? cards.first
        if let next, let group = value.review.groups.values.first(where: { $0.cards.contains(next) }),
           let context = context(card: next, group: group, content: value) {
            practice.phase = .question(context)
            loadImages(context)
        } else {
            practice.phase = .finished
            imageTask?.cancel()
            images = []
        }
        self.practice = practice
    }

    private func loadImages(_ context: BuiltInReviewCardContext) {
        imageTask?.cancel()
        images = []
        imageTask = Task { [weak self, io] in
            let images = (try? await io.savedImages(context: context)) ?? []
            guard let self, !Task.isCancelled,
                  self.practice?.phase.context?.card == context.card,
                  self.practice?.phase.context?.snapshot == context.snapshot else { return }
            self.images = images
        }
    }

    private func clearUnsavedSession(cancelWrite: Bool = false) {
        if cancelWrite {
            writeIdentity = UUID()
            writeTask?.cancel()
            isMutating = false
        }
        draft = nil
        practice = nil
        imageTask?.cancel()
        images = []
        if route == .practice { route = .overview }
        stopOwnSpeech()
    }

    private func sameLifetime(_ lhs: LingroveNotebookSnapshot, _ rhs: LingroveNotebookSnapshot) -> Bool {
        lhs.workspaceId == rhs.workspaceId && lhs.notebookId == rhs.notebookId && lhs.generation == rhs.generation
    }

    private func samePresentedData(_ lhs: NotebookBuiltInReviewSnapshot, _ rhs: NotebookBuiltInReviewSnapshot) -> Bool {
        lhs.scope == rhs.scope && lhs.schedulerSettings == rhs.schedulerSettings && lhs.review.links == rhs.review.links
            && Set(lhs.review.groups.values.flatMap(\.enrollments)) == Set(rhs.review.groups.values.flatMap(\.enrollments))
            && Set(lhs.review.groups.values.flatMap(\.cards)) == Set(rhs.review.groups.values.flatMap(\.cards))
    }

    private func speechTarget(_ context: BuiltInReviewCardContext, answer: Bool) -> SpeechTarget {
        .init(ownerID: speechOwnerID, itemID: "builtInReview." + context.card.cardId + (answer ? ".back" : ".front"))
    }

    private func stopOwnSpeech() {
        guard let target = speech?.activeTarget, target.ownerID == speechOwnerID else { return }
        speech?.stop(target: target)
    }
}
