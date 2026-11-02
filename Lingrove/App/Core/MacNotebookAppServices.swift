import Foundation
import Logging

/// The notebook branch of the app's composition root. LingroveAppEnvironment owns it for the
/// process lifetime and lends the same repository to capture/CLI, sync and built-in review.
/// Keeping this assembly separate makes failure and shutdown testable without starting AX,
/// keyboard monitors or a model runtime. An unreadable database never becomes an empty library.
@MainActor
final class MacNotebookAppServices {
    let repository: MacNotebookRepository?
    let vocabulary: VocabularyStore
    let synchronization: MacNotebookSyncController?
    let builtInReview: BuiltInReviewController?
    private var shutdownTask: Task<Void, Never>?
    private var stopped = false

    init(databaseURL: URL, mediaDirectoryURL: URL, account: AccountSessionService,
         speech: LearningSpeechController? = nil) {
        do {
            let repository = try MacNotebookRepository(databaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
            self.repository = repository
            vocabulary = VocabularyStore(repository: repository)
            synchronization = MacNotebookSyncController(repository: repository, account: account)
            let review = BuiltInReviewController(repository: repository, speech: speech)
            builtInReview = review
            vocabulary.onRequestBuiltInReview = { [weak review] selection in review?.show(selection: selection) }
        } catch {
            repository = nil
            vocabulary = .unavailable(error)
            synchronization = nil
            builtInReview = nil
        }
    }

    func start() {
        guard !stopped, shutdownTask == nil else { return }
        synchronization?.start()
    }

    /// Revoke network/window work synchronously before awaiting outstanding capture/CLI writes.
    /// Settings and window closure never call this process-lifetime operation.
    func stop() {
        guard !stopped else { return }
        stopped = true
        synchronization?.shutdown()
        builtInReview?.shutdown()
    }

    /// One shared task also makes repeated termination requests await the same drain. The CLI
    /// mailbox is stopped by AppDelegate first, so no new external write can enter during this wait.
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task {
            // Drain admitted local writes before retiring the durable scope. Retiring it first
            // would correctly fence network callbacks but also reject those local saved intents.
            async let corpus: Void = vocabulary.shutdown()
            await builtInReview?.shutdownAfterDraining()
            await corpus
            stop()
            do { try repository?.shutdown() } catch {
                LingroveLogger.learning.error("Notebook connection could not close after draining writes")
            }
        }
        shutdownTask = task
        await task.value
    }
}
