import Combine

/// The three destinations belong to the reusable notebook window, not to the menu bar or
/// the corpus browser's own categories. Keeping this closed set prevents outer navigation
/// from accidentally becoming a second corpus filtering model.
enum NotebookWorkspaceDestination: String, CaseIterable, Identifiable {
    case corpus, review, progress
    var id: Self { self }
}

/// The window controller owns this small presentation model for its entire lifetime. The
/// sidebar observes it; requests travel back to the controller so AppKit can check sheets
/// before removing any hosted destination. A pending sidebar request belongs to that window
/// lifetime, not to a List update; it owns no repository, account or review session.
@MainActor
final class NotebookWorkspaceNavigation: ObservableObject {
    @Published private(set) var destination: NotebookWorkspaceDestination = .corpus
    @Published var hasSheet = false {
        didSet { if hasSheet { cancelPendingRequest() } }
    }
    var onSelect: ((NotebookWorkspaceDestination) -> Void)?
    private var selectionTask: Task<Void, Never>?

    func request(_ destination: NotebookWorkspaceDestination) {
        cancelPendingRequest()
        guard !hasSheet, self.destination != destination else { return }
        // AppKit's List can write its selection binding while SwiftUI is updating the view.
        // The controller pauses/resumes observable sessions and replaces hosting views, so its
        // callback must run in a later MainActor job, after that synchronous binding write ends.
        // Cancellation makes rapid selections latest-wins without publishing an interim page.
        selectionTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.selectionTask = nil
            guard !self.hasSheet, self.destination != destination else { return }
            self.onSelect?(destination)
        }
    }

    /// Close, a sheet, or an explicit source link revokes the queued click. Check cancellation
    /// before clearing task ownership above, so an old job cannot consume a newer request.
    func cancelPendingRequest() {
        selectionTask?.cancel()
        selectionTask = nil
    }

    func show(_ destination: NotebookWorkspaceDestination) {
        cancelPendingRequest()
        guard self.destination != destination else { return }
        self.destination = destination
    }
}
