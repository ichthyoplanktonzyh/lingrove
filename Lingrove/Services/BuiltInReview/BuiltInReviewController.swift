import LingroveNotebook

/// Public composition hook for native built-in review. LingroveAppEnvironment owns one facade
/// beside the shared repository and speech controller. Corpus callbacks and global commands
/// may open it; opening a destination never enrolls it or changes optional Anki behavior.
@MainActor
final class BuiltInReviewController {
    private let session: BuiltInReviewSession
    private let windowController: BuiltInReviewWindowController

    var onOpenSource: ((VocabularySelection) -> Void)? {
        didSet { session.onOpenSource = onOpenSource }
    }

    init(repository: MacNotebookRepository, speech: LearningSpeechController? = nil) {
        let session = BuiltInReviewSession(repository: repository, speech: speech)
        self.session = session
        windowController = BuiltInReviewWindowController(session: session)
    }

    func show(selection: VocabularySelection? = nil) { windowController.show(selection: selection) }

    /// Called by the app's shutdown, not by settings or corpus window lifetime. This retires
    /// only this facade's tasks/window; the app graph still owns the repository and speech.
    func shutdown() { windowController.shutdown() }

    /// Explicit app Quit closes admission but lets an already-submitted rating/edit finish.
    /// Ordinary window closure still cancels its unsaved UI session as before.
    func prepareForShutdown() { session.prepareForShutdown() }

    func shutdownAfterDraining() async {
        await session.shutdownAfterDraining()
        windowController.shutdown()
    }
}
