import Combine
import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The app's one review facade owns this MainActor presentation model. The repository
/// owns persistence for the whole app; this model owns only navigation, an unsaved sheet, the
/// pinned question and cancellable IO. Closing it never shuts down corpus, sync or autocomplete.
@MainActor
final class BuiltInReviewSession: ObservableObject {
    // @Published tells the hosted SwiftUI root to redraw; these properties are temporary
    // presentation state. A durable change still requires an explicit shared-engine command.
    @Published private(set) var participationRevision = UUID()
    @Published private(set) var content: NotebookBuiltInReviewSnapshot?
    @Published var browsing = BuiltInReviewBrowsing()
    @Published private(set) var addedCount = 0
    @Published var route: BuiltInReviewRoute = .overview
    @Published var noteDraft: ReviewNoteEditorDraft?
    @Published var noteTypeDraft: ReviewNoteTypeEditorDraft?
    @Published var draft: BuiltInReviewDraft?
    @Published var batchDraft: BuiltInReviewBatchDraft?
    @Published private(set) var practice: BuiltInReviewPractice?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var message: String?
    @Published private(set) var images: [BuiltInReviewSavedImage] = []
    @Published private(set) var savedAudio: [BuiltInReviewSavedAudio] = []
    var onOpenSource: ((VocabularySelection) -> Void)?
    var onBrowseCorpus: (() -> Void)?
    var onOpenProgress: (() -> Void)?
    var materialStore: VocabularyStore?
    var materialSpeech: (any SpeechExporting)?

    private let repository: MacNotebookRepository
    private let io: BuiltInReviewIO
    let speech: LearningSpeechController?
    private let speechOwnerID = UUID()
    private var savedPlaybackID: String?
    private var subscriptions = Set<AnyCancellable>()
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var lifetime = UUID()
    private var readIdentity = UUID()
    private var writeIdentity = UUID()
    // Task retirement and UI publication have different lifetimes. Invalidating a stale Card
    // revokes its presentation identity, while the admitted task remains retained for Quit's drain.
    private var writePresentationIdentity = UUID()
    private var isVisible = false
    private var isActive = false
    private var isShuttingDown = false
    private var isPublishing = false
    private var refreshAfterOwnChange = false
    private var preferredCardAfterResume: String?
    private var pendingBatchSelections: [VocabularySelection]?

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
        isActive = true
        // Opening is navigation only. A round starts from its explicit Start action, so a
        // first visit with an empty queue can never manufacture a completed round.
        route = selection.map(BuiltInReviewRoute.sense) ?? .overview
        reload()
    }

    func close() {
        isVisible = false
        isActive = false
        lifetime = UUID()
        readTask?.cancel()
        // Save/rating is already an explicit accepted intent. Keep its task even on ordinary
        // Close, so a subsequent Quit can await it. Only its old UI lifetime is revoked; it
        // cannot publish an old route or draft into a reopened window.
        imageTask?.cancel()
        readTask = nil
        imageTask = nil
        draft = nil
        noteTypeDraft = nil
        noteDraft = nil
        batchDraft = nil
        pendingBatchSelections = nil
        browsing = .init()
        addedCount = 0
        practice = nil
        content = nil
        images = []
        savedAudio = []
        message = nil
        isRefreshing = false
        isMutating = writeTask != nil
        refreshAfterOwnChange = false
        preferredCardAfterResume = nil
        stopOwnSpeech()
    }

    /// Switching workspace destinations pauses reads, image work and speech without discarding
    /// the pinned card/navigation state. Sheets prevent navigation before this entry point, and
    /// an admitted write may finish in the background; no second review writer is created.
    func suspend() {
        guard isVisible, isActive else { return }
        isActive = false
        readIdentity = UUID()
        readTask?.cancel(); readTask = nil
        imageTask?.cancel(); imageTask = nil
        isRefreshing = false
        images = []
        savedAudio = []
        stopOwnSpeech()
    }

    /// Re-entering always validates the current repository scope before displaying its card.
    /// A hidden account switch therefore cannot reveal the previous account for one frame.
    func resume() {
        guard isVisible, !isActive, !isShuttingDown else { return }
        isActive = true
        reload(afterOwnChange: refreshAfterOwnChange, preferredCardID: preferredCardAfterResume)
    }

    func reload(afterOwnChange: Bool = false, preferredCardID: String? = nil) {
        guard isVisible, isActive else { return }
        let isOwnChange = afterOwnChange || refreshAfterOwnChange
        let preferredCard = preferredCardID ?? preferredCardAfterResume
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
            if !sameLifetime(previous.scope, scope) {
                content = nil; route = .overview; browsing = .init(); addedCount = 0
            }
            message = BuiltInReviewCopy.text("message.changed")
        }
        isRefreshing = true
        readTask = Task { [weak self, io] in
            do {
                let value = try await io.load(scope: scope, now: Date())
                guard let self, self.isVisible, self.isActive, self.lifetime == savedLifetime, self.readIdentity == operation,
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
                if let previous, !isOwnChange, !self.samePresentedData(previous, value) {
                    self.clearUnsavedSession(cancelWrite: true)
                    self.message = BuiltInReviewCopy.text("message.changed")
                }
                self.content = value
                self.isRefreshing = false
                self.preparePendingBatch()
                self.refreshAfterOwnChange = false
                self.preferredCardAfterResume = nil
                self.restorePracticeAfterReload(ownChange: isOwnChange, preferredCardID: preferredCard)
            } catch {
                guard let self, self.lifetime == savedLifetime, self.readIdentity == operation, !Task.isCancelled else { return }
                self.isRefreshing = false
                self.content = nil
                self.clearUnsavedSession(cancelWrite: true)
                self.message = BuiltInReviewCopy.text("error.load")
            }
        }
    }

    /// Detail navigation records the caller independently of persistence. Returning after an
    /// enrollment keeps the add search, while management returns to its exact status filter.
    func showDetail(_ selection: VocabularySelection) {
        browsing.detailOrigin = route == .adding ? .adding : .content
        addedCount = 0
        route = .sense(selection)
    }

    func showContent(filter: BuiltInReviewContentFilter = .active) {
        browsing.filter = filter
        browsing.search = ""
        route = .content
    }

    func showAdding() { addedCount = 0; route = .adding }

    func prepare(selection: VocabularySelection, additional: Bool = false, basedOn value: NotebookBuiltInReviewSnapshot) {
        guard canAct(in: value.scope) else { return }
        do { draft = try .init(content: value, selection: selection, additional: additional) } catch {
            message = BuiltInReviewCopy.text("error.source")
        }
    }

    func requestBatch(_ selections: [VocabularySelection]) {
        pendingBatchSelections = selections
        preparePendingBatch()
    }

    private func preparePendingBatch() {
        guard let selections = pendingBatchSelections, let content, !isBusy else { return }
        pendingBatchSelections = nil
        do { batchDraft = try .init(content: content, selections: selections) } catch { message = BuiltInReviewCopy.text("error.source") }
    }

    func saveBatch(_ batch: BuiltInReviewBatchDraft) {
        guard batchDraft?.id == batch.id, !batch.drafts.isEmpty else { return }
        mutate(.batch(batch), scope: batch.content.scope, destination: route == .adding ? .adding : .content)
    }

    /// The corpus may inspect participation while Review is hidden. This read returns a value
    /// to its caller and never opens a review route or starts background presentation work.
    func inspectParticipation() async throws -> NotebookBuiltInReviewSnapshot {
        let scope = try repository.snapshot()
        let value = try await io.load(scope: scope, now: Date())
        guard try repository.snapshot() == scope else { throw VocabularyError.editConflict }
        return value
    }

    func savedMaterialMedia(_ draft: BuiltInReviewDraft) async -> [ReviewMaterialPreparedMedia] {
        (try? await io.materialMedia(draft: draft)) ?? []
    }

    func edit(card: Card, link: LingroveNotebookCardLink, selection: VocabularySelection,
              basedOn value: NotebookBuiltInReviewSnapshot) {
        guard canAct(in: value.scope) else { return }
        draft = .init(content: value, card: card, link: link, selection: selection)
    }

    func save(_ value: BuiltInReviewDraft) {
        guard draft?.id == value.id, value.canSave else { return }
        let destination: BuiltInReviewRoute = route == .practice ? .practice : .sense(value.selection)
        let cardID: String?
        if case let .editing(card, _) = value.purpose { cardID = card.cardId } else { cardID = nil }
        mutate(.save(value), scope: value.snapshot, destination: destination, preferredCardID: cardID)
    }

    /// Corpus admission keeps the corpus window in place. The app-owned session retains this
    /// accepted writer even while Review is hidden, so normal Quit still drains its transaction.
    func enrollFromCorpus(_ selection: VocabularySelection) async -> String? {
        guard !isShuttingDown, writeTask == nil else { return BuiltInReviewCopy.text("error.write") }
        let scope: LingroveNotebookSnapshot
        do { scope = try repository.snapshot() } catch { return BuiltInReviewCopy.text("error.load") }
        isMutating = true
        var failure: String?
        let task = Task { [io, repository] in
            do {
                let value = try await io.load(scope: scope, now: Date())
                try await io.perform(.enrollNotes([selection], value.defaultNoteType, scope))
                repository.publishChange()
            } catch { failure = BuiltInReviewCopy.text("error.write") }
        }
        writeTask = task
        await task.value
        writeTask = nil; isMutating = false
        participationRevision = UUID()
        return failure
    }

    func enrollDefault(selection: VocabularySelection, basedOn value: NotebookBuiltInReviewSnapshot) {
        guard canAct(in: value.scope) else { return }
        mutate(.enrollNotes([selection], value.defaultNoteType, value.scope), scope: value.scope, destination: .content)
    }

    /// Type drafts pin the same source scope as a review question. Saving a definition is a
    /// shared change, distinct from editing any single card or starting a round.
    func editNoteType(_ type: ReviewNoteType? = nil) {
        guard let content, !isBusy else { return }
        noteTypeDraft = .init(type: type ?? content.defaultNoteType, scope: content.scope)
    }

    func saveNoteType(_ draft: ReviewNoteTypeEditorDraft) {
        guard noteTypeDraft?.id == draft.id else { return }
        var value = draft.type
        value.revision = (draft.expected?.revision ?? 0) + 1
        mutate(.noteType(value, draft.expected, draft.scope, draft.makeDefault), scope: draft.scope, destination: route)
    }

    func editNote(_ model: NotebookReviewNoteCard) {
        guard let content, !isBusy else { return }
        noteDraft = .init(model: model, scope: content.scope)
    }

    func saveNote(_ draft: ReviewNoteEditorDraft) {
        guard noteDraft?.id == draft.id else { return }
        mutate(.note(draft), scope: draft.scope, destination: route)
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
        let due = dueCards(selection: selection, in: value)
        guard !due.isEmpty else { route = .overview; return }
        draft = nil
        message = nil
        practice = .init(selection: selection, initialDueCount: due.count)
        route = .practice
        advancePractice()
    }

    func reveal() {
        guard isActive, !isBusy, case let .question(context) = practice?.phase else { return }
        practice?.phase = .answer(context)
    }

    func rate(_ rating: ReviewRating) {
        guard isActive, !isBusy, case let .answer(context) = practice?.phase else { return }
        mutate(.rate(context, rating, Date(), TimeZone.current.identifier), scope: context.snapshot, destination: .practice)
    }

    func undo(_ undo: BuiltInReviewUndoAction) {
        mutate(.undo(undo), scope: undo.action.scope, destination: route, preferredCardID: undo.identity.cardID)
    }

    func endPractice() {
        stopOwnSpeech()
        imageTask?.cancel()
        images = []
        savedAudio = []
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

    func playSavedAudio(_ audio: BuiltInReviewSavedAudio, context: BuiltInReviewCardContext) {
        guard isActive, practice?.phase.context?.card == context.card else { return }
        if savedPlaybackID == audio.id, speech?.activeTarget?.ownerID == speechOwnerID,
           speech?.activeTarget?.itemID == "review.audio" {
            materialSpeech?.stop(ownerID: speechOwnerID)
            savedPlaybackID = nil
            return
        }
        let language = BuiltInReviewSource.value(context.group.selection, in: context.snapshot)?.entry.language ?? .english
        do {
            try materialSpeech?.audition(.init(data: audio.data, fileExtension: audio.fileExtension),
                ownerID: speechOwnerID, language: language)
            savedPlaybackID = audio.id
        } catch { message = error.localizedDescription }
    }

    func resolvedParts(_ context: BuiltInReviewCardContext, answer: Bool) -> [ReviewResolvedPart]? {
        let text = answer ? context.card.backText : context.card.frontText
        let generated = answer ? context.link.generatedContent?.backText : context.link.generatedContent?.frontText
        guard text == generated, let plan = context.link.materialPlan,
              let source = BuiltInReviewSource.value(context.group.selection, in: context.snapshot),
              let resolved = try? ReviewMaterialResolver.resolve(entry: source.entry, sense: source.sense, plan: plan) else { return nil }
        return answer ? resolved.back : resolved.front
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
        writePresentationIdentity = operation
        message = nil
        isMutating = true
        writeTask = Task { [weak self, io, repository] in
            do {
                try await io.perform(command)
                guard let self else { repository.publishChange(); return }
                self.committed(command, operation: operation, savedLifetime: savedLifetime,
                    destination: destination, preferredCardID: preferredCardID)
            } catch {
                self?.failed(error, operation: operation, savedLifetime: savedLifetime, scope: scope)
            }
        }
    }

    private func committed(_ command: BuiltInReviewIO.Command, operation: UUID, savedLifetime: UUID,
                           destination: BuiltInReviewRoute, preferredCardID: String?) {
        guard writeIdentity == operation else { repository.publishChange(); return }
        isMutating = false
        writeTask = nil
        // Commit visibility belongs to the repository even if the window closed during IO.
        // Revoking presentation lifetime must not hide a durable write from corpus observers.
        isPublishing = lifetime == savedLifetime && writePresentationIdentity == operation
        repository.publishChange()
        isPublishing = false
        guard isVisible, lifetime == savedLifetime, writePresentationIdentity == operation else { return }
        draft = nil
        noteTypeDraft = nil
        noteDraft = nil
        batchDraft = nil
        route = destination
        addedCount = 0
        if case let .enrollNotes(selections, _, _) = command { addedCount = selections.count }
        if case let .save(value) = command, case .enrollment = value.purpose { addedCount = 1 }
        if case let .batch(value) = command { addedCount = value.drafts.count; browsing.selectedSenseIDs = [] }
        if case .rate = command { practice?.answered += 1 }
        if case .undo = command { practice?.answered = max(0, (practice?.answered ?? 0) - 1) }
        stopOwnSpeech()
        // A hidden destination may cancel this next read after a rating already committed.
        // Preserve its identity until publication, so Resume still advances the same round.
        refreshAfterOwnChange = true
        preferredCardAfterResume = preferredCardID
        if isActive { reload(afterOwnChange: true, preferredCardID: preferredCardID) }
    }

    private func failed(_ error: any Error, operation: UUID, savedLifetime: UUID, scope: LingroveNotebookSnapshot) {
        guard writeIdentity == operation else { return }
        isMutating = false
        writeTask = nil
        guard isVisible, lifetime == savedLifetime, writePresentationIdentity == operation else { return }
        // An operational failure retains the exact draft/batch intent for retry. A changed
        // owner revokes it, because a retry must never borrow a new account or generation.
        if error is CancellationError || (try? repository.snapshot()) != scope { clearUnsavedSession() }
        message = BuiltInReviewCopy.text(error is CancellationError ? "message.changed" : "error.write")
        reload()
    }

    private func canAct(in scope: LingroveNotebookSnapshot) -> Bool {
        guard isVisible, isActive, !isBusy, !isShuttingDown else { return false }
        guard (try? repository.snapshot()) == scope else {
            clearUnsavedSession(cancelWrite: true)
            message = BuiltInReviewCopy.text("message.changed")
            reload()
            return false
        }
        return true
    }

    private func repositoryDidChange() {
        // Participation can change without a corpus revision. Source-detail readers observe
        // this identity even while the review destination is suspended.
        participationRevision = UUID()
        guard isVisible, isActive, !isPublishing else { return }
        // A notification can describe only an upload ACK. Disable actions while re-reading,
        // then discard a draft/question only if its actual scope or review rows changed.
        reload()
    }

    func dueCards(selection: VocabularySelection?, in value: NotebookBuiltInReviewSnapshot) -> [Card] {
        value.queue.filter { card in
            guard let selection else { return true }
            return value.review.groups[selection.senseID]?.cards.contains { $0.cardId == card.cardId } == true
        }
    }

    private func advancePractice(preferredCardID: String? = nil) {
        guard let value = content, var practice else { return }
        let cards = dueCards(selection: practice.selection, in: value)
        let next = preferredCardID.flatMap { id in cards.first { $0.cardId == id } } ?? cards.first
        if let next, let group = value.review.groups.values.first(where: { $0.cards.contains(next) }),
           let context = context(card: next, group: group, content: value) {
            practice.phase = .question(context)
            loadImages(context)
        } else {
            practice.phase = .finished
            imageTask?.cancel()
            images = []
        savedAudio = []
        }
        self.practice = practice
    }

    private func restorePracticeAfterReload(ownChange: Bool, preferredCardID: String?) {
        if ownChange, practice != nil {
            advancePractice(preferredCardID: preferredCardID)
        } else if let context = practice?.phase.context {
            loadImages(context)
        }
    }

    private func loadImages(_ context: BuiltInReviewCardContext) {
        imageTask?.cancel()
        images = []
        savedAudio = []
        imageTask = Task { [weak self, io] in
            let images = (try? await io.savedImages(context: context)) ?? []
            let audio = (try? await io.savedAudio(context: context)) ?? []
            guard let self, self.isVisible, self.isActive, !Task.isCancelled,
                  self.practice?.phase.context?.card == context.card,
                  self.practice?.phase.context?.snapshot == context.snapshot else { return }
            self.images = images
            self.savedAudio = audio
        }
    }

    private func clearUnsavedSession(cancelWrite: Bool = false) {
        if cancelWrite {
            writePresentationIdentity = UUID()
            writeTask?.cancel()
            // Retain the task until its completion path retires it, including a cancelled
            // command already executing inside SQLite. Quit must still observe that drain.
            isMutating = writeTask != nil
        }
        draft = nil
        noteTypeDraft = nil
        noteDraft = nil
        batchDraft = nil
        practice = nil
        imageTask?.cancel()
        images = []
        savedAudio = []
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
            && lhs.noteCards == rhs.noteCards && lhs.noteTypes == rhs.noteTypes
    }

    private func speechTarget(_ context: BuiltInReviewCardContext, answer: Bool) -> SpeechTarget {
        .init(ownerID: speechOwnerID, itemID: "builtInReview." + context.card.cardId + (answer ? ".back" : ".front"))
    }

    private func stopOwnSpeech() {
        savedPlaybackID = nil
        materialSpeech?.stop(ownerID: speechOwnerID)
        guard let target = speech?.activeTarget, target.ownerID == speechOwnerID else { return }
        speech?.stop(target: target)
    }
}
