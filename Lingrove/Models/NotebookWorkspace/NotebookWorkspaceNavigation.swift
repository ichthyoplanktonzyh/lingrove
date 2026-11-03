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
/// before removing any hosted destination. It owns no repository, account or review session.
@MainActor
final class NotebookWorkspaceNavigation: ObservableObject {
    @Published private(set) var destination: NotebookWorkspaceDestination = .corpus
    @Published var hasSheet = false
    var onSelect: ((NotebookWorkspaceDestination) -> Void)?

    func request(_ destination: NotebookWorkspaceDestination) { onSelect?(destination) }

    func show(_ destination: NotebookWorkspaceDestination) {
        guard self.destination != destination else { return }
        self.destination = destination
    }
}
