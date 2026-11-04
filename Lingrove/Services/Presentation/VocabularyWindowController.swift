import AppKit
import Combine
import LingroveNotebook
import SwiftUI

/// The app environment retains this single activating notebook window. It owns only outside
/// navigation and hosted presentation lifetimes: the complete original corpus root is retained,
/// review borrows the existing facade/session, and Progress is injected by the composition root.
/// Closing the window never closes repository, account, sync, speech or autocomplete services.
@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate {
    let navigation = NotebookWorkspaceNavigation()
    var onShowSettings: (() -> Void)?
    var onShowAccount: (() -> Void)?
    private(set) var corpusHost: NSHostingController<VocabularyNotebookRoot>?
    private let store: VocabularyStore
    private let speech: LearningSpeechController
    private let learning: VocabularyNotebookSession
    private let review: AnkiReviewController?
    private let search: VocabularySearchController?
    private let builtInReview: BuiltInReviewController?
    private let account: AccountSessionService?
    private let sync: MacNotebookSyncController?
    private let progressContent: (@MainActor (Bool) -> AnyView)?
    private let preferences: UserDefaults
    private let learningSettings: LanguageLearningSettings
    private var subscriptions = Set<AnyCancellable>()
    private var host: NotebookWorkspaceHostController?
    private var reviewHost: NSHostingController<NotebookReviewDestinationView>?
    let reviewNavigation = NotebookReviewDestinationModel()
    private var progressHost: NSHostingController<AnyView>?
    private var isOpen = false
    private var hasOpenedReview = false
    private var progressIsActive = false
    private var pendingOpen: OpenRequest?

    /// External deep links can arrive while an editor owns a sheet. Retain the latest request
    /// until that sheet ends, instead of replacing its hosting graph and losing an unsaved draft.
    private enum OpenRequest {
        case corpus(entry: UUID?, sense: UUID?)
        case review(VocabularySelection?)
    }

    init(store: VocabularyStore, speech: LearningSpeechController, explanationService: LearningExplanationService? = nil,
         dictionaryProvider: any LearningDictionaryProviding, learningSettings: LanguageLearningSettings,
         review: AnkiReviewController? = nil, search: VocabularySearchController? = nil, preferences: UserDefaults = .standard,
         builtInReview: BuiltInReviewController? = nil, account: AccountSessionService? = nil,
         sync: MacNotebookSyncController? = nil, progressContent: (@MainActor (Bool) -> AnyView)? = nil) {
        self.store = store
        self.speech = speech
        self.review = review
        self.search = search
        self.builtInReview = builtInReview
        self.account = account
        self.sync = sync
        self.progressContent = progressContent
        self.preferences = preferences
        self.learningSettings = learningSettings
        learning = VocabularyNotebookSession(service: explanationService, provider: dictionaryProvider,
            settings: learningSettings.dictionary)
        super.init(window: nil)
        navigation.onSelect = { [weak self] in self?.navigate(to: $0) }
        builtInReview?.session.materialStore = store
        builtInReview?.session.materialSpeech = review?.speech ?? speech
        builtInReview?.session.onBrowseCorpus = { [weak self] in self?.navigate(to: .corpus) }
        builtInReview?.session.onOpenProgress = { [weak self] in self?.navigate(to: .progress) }
        reviewNavigation.onChange = { [weak self] target in
            guard let self, self.navigation.destination == .review else { return }
            let active = target == .lingrove
            self.builtInReview?.setPresentationActive(active)
            if active { self.builtInReview?.session.resume() } else { self.builtInReview?.session.suspend() }
        }
        store.openSelection = { [weak self] in self?.show(selectedID: $0?.entryID, senseID: $0?.senseID) }
        // A closed window may not receive SwiftUI onAppear until after resume(). Retire the
        // reading target directly so reopening cannot issue a lookup for the previous owner.
        store.$scopeIdentity.dropFirst().sink { [weak self] _ in self?.learning.reset() }.store(in: &subscriptions)
        // A draft can be opened and cancelled before AppKit has mounted a sheet. Observe its
        // binding too, so a queued external deep link never depends on an animation completing.
        builtInReview?.session.$draft.dropFirst().sink { [weak self] _ in self?.sheetChanged() }.store(in: &subscriptions)
        builtInReview?.session.$batchDraft.dropFirst().sink { [weak self] _ in self?.sheetChanged() }.store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { nil }

    func show(selectedID: UUID? = nil, senseID: UUID? = nil) {
        open(.corpus(entry: selectedID, sense: senseID))
    }

    /// BuiltInReviewController's public show hook routes here. It is the same session and one
    /// exact window as corpus/source/CLI navigation, rather than a second writable review window.
    func showReview(selection: VocabularySelection? = nil) { open(.review(selection)) }

    /// Preparing without activation lets isolated native checks inspect the actual host. The
    /// larger window preserves the original corpus's 760-point minimum after adding the sidebar.
    func prepareWindow() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1240, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NotebookWorkspaceCopy.title(.corpus)
        window.identifier = .init("LingroveVocabulary")
        window.minSize = CGSize(width: 1000, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("LingroveNotebookWorkspace")
        window.center()
        let host = NotebookWorkspaceHostController(sidebar: .init(navigation: navigation, account: account, sync: sync,
            openSettings: { [weak self] in self?.onShowSettings?() },
            openAccount: { [weak self] in self?.onShowAccount?() }))
        self.host = host
        window.contentViewController = host
        self.window = window
        corpusHost = makeCorpusHost()
        if let corpusHost { host.show(corpusHost, preservingCorpusToolbar: true) }
        builtInReview?.attachPresentation(to: window)
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] notification in
                // AppKit sheet notifications are synchronous on the main actor. Yield once on
                // dismissal so SwiftUI can first release the sheet's own presentation binding.
                MainActor.assumeIsolated {
                    if notification.name == NSWindow.willBeginSheetNotification {
                        self?.navigation.hasSheet = true
                    } else { self?.sheetChanged() }
                }
            }.store(in: &subscriptions)
        }
    }

    func navigate(to destination: NotebookWorkspaceDestination) {
        guard isOpen, !hasBlockingSheet else { return }
        display(destination)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !hasBlockingSheet else {
            sender.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        navigation.cancelPendingRequest()
        deactivateCurrentDestination()
        isOpen = false
        pendingOpen = nil
        hasOpenedReview = false
        builtInReview?.closePresentation()
        navigation.hasSheet = false
    }

    private var hasBlockingSheet: Bool {
        window?.attachedSheet != nil || builtInReview?.session.draft != nil || builtInReview?.session.batchDraft != nil
            || builtInReview?.session.noteTypeDraft != nil || builtInReview?.session.noteDraft != nil
    }

    private func open(_ request: OpenRequest) {
        prepareWindow()
        isOpen = true
        if hasBlockingSheet {
            pendingOpen = request
        } else {
            apply(request)
        }
        store.loadIfNeeded()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func apply(_ request: OpenRequest) {
        switch request {
        case let .corpus(entry, sense):
            if let entry {
                // Explicit source/CLI links must reveal the real entry+sense through any old
                // browser filter. Ordinary navigation never replaces this retained root.
                if navigation.destination == .corpus { deactivateCurrentDestination() }
                corpusHost = makeCorpusHost(selectedID: entry, senseID: sense)
            }
            display(.corpus)
        case let .review(selection):
            reviewNavigation.target = .lingrove
            if let builtInReview {
                builtInReview.session.open(selection: selection)
                hasOpenedReview = true
            }
            display(.review)
        }
    }

    private func display(_ destination: NotebookWorkspaceDestination) {
        navigation.cancelPendingRequest()
        window?.title = NotebookWorkspaceCopy.title(destination)
        if navigation.destination != destination {
            // Clear a focused corpus field editor before review becomes visible. A later
            // number/Space belongs to practice only after the original editor has resigned.
            window?.makeFirstResponder(nil)
            deactivateCurrentDestination()
            navigation.show(destination)
        }
        switch destination {
        case .corpus:
            if let corpusHost { host?.show(corpusHost, preservingCorpusToolbar: true) }
            learning.resume()
            search?.activate()
        case .review: displayReview()
        case .progress:
            setProgressActive(true)
            if let progressHost { host?.show(progressHost) }
        }
    }

    private func displayReview() {
        if let builtInReview {
            if !hasOpenedReview {
                builtInReview.session.open(selection: nil)
                hasOpenedReview = true
            } else if reviewNavigation.target == .lingrove { builtInReview.session.resume() }
            if reviewHost == nil {
                let reviewHost = NotebookWorkspaceHostController.destinationHost(
                    rootView: NotebookReviewDestinationView(navigation: reviewNavigation, session: builtInReview.session, anki: review))
                self.reviewHost = reviewHost
            }
            if let reviewHost { host?.show(reviewHost) }
            builtInReview.setPresentationActive(reviewNavigation.target == .lingrove)
            if reviewNavigation.target == .anki { builtInReview.session.suspend() }
        } else { showUnavailable("state.reviewUnavailable") }
    }

    private func deactivateCurrentDestination() {
        switch navigation.destination {
        case .corpus:
            learning.cancel()
            search?.suspend()
            if let target = speech.activeTarget, target.itemID.hasPrefix("vocabulary.") { speech.stop(target: target) }
        case .review:
            builtInReview?.setPresentationActive(false)
            builtInReview?.session.suspend()
        case .progress: setProgressActive(false)
        }
    }

    private func setProgressActive(_ active: Bool) {
        guard progressHost == nil || progressIsActive != active else { return }
        progressIsActive = active
        let view = progressContent?(active) ?? unavailable("state.progressUnavailable")
        if let progressHost { progressHost.rootView = view } else {
            progressHost = NotebookWorkspaceHostController.destinationHost(rootView: view)
        }
    }

    private func showUnavailable(_ key: String) {
        host?.show(NotebookWorkspaceHostController.destinationHost(rootView: unavailable(key)))
    }

    private func unavailable(_ key: String) -> AnyView {
        AnyView(ContentUnavailableView(NotebookWorkspaceCopy.text(key), systemImage: "exclamationmark.circle")
            .frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    private func makeCorpusHost(selectedID: UUID? = nil, senseID: UUID? = nil) -> NSHostingController<VocabularyNotebookRoot> {
        NotebookWorkspaceHostController.destinationHost(rootView: VocabularyNotebookRoot(
            settings: learningSettings, store: store, speech: speech,
            selectedID: selectedID, selectedSenseID: senseID, learning: learning, review: review, builtInReview: builtInReview?.session,
            search: search, preferences: preferences))
    }

    private func sheetChanged() {
        navigation.hasSheet = hasBlockingSheet
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.navigation.hasSheet = self.hasBlockingSheet
            guard !self.hasBlockingSheet else { return }
            if self.isOpen, let pending = self.pendingOpen {
                self.pendingOpen = nil
                self.apply(pending)
            }
        }
    }
}
