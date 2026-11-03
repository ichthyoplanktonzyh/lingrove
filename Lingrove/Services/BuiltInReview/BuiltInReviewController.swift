import AppKit
import LingroveNotebook

/// Public composition hook for native built-in review. LingroveAppEnvironment owns one facade
/// beside the shared repository and speech controller. Corpus callbacks and global commands
/// may open it; opening a destination never enrolls it or changes optional Anki behavior.
/// A composition-supplied route embeds this same session in the notebook workspace. The legacy
/// standalone host remains available for isolated clients without constructing another writer.
@MainActor
final class BuiltInReviewController {
    let session: BuiltInReviewSession
    private let windowController: BuiltInReviewWindowController
    var onShow: ((VocabularySelection?) -> Void)?

    var onOpenSource: ((VocabularySelection) -> Void)? {
        didSet { session.onOpenSource = onOpenSource }
    }

    init(repository: MacNotebookRepository, speech: LearningSpeechController? = nil) {
        let session = BuiltInReviewSession(repository: repository, speech: speech)
        self.session = session
        windowController = BuiltInReviewWindowController(session: session)
    }

    func show(selection: VocabularySelection? = nil) {
        if let onShow { onShow(selection) } else { windowController.show(selection: selection) }
    }

    /// A borrowed host is never owned or closed by this facade. Only its existing, exact-window
    /// keyboard monitor is attached; the workspace controls which destination is visible.
    func attachPresentation(to window: NSWindow) { windowController.attachPresentation(to: window) }
    func setPresentationActive(_ active: Bool) { windowController.setPresentationActive(active) }
    func closePresentation() {
        windowController.setPresentationActive(false)
        session.close()
    }

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
