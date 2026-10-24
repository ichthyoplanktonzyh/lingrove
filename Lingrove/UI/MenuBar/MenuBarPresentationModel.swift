import Combine
import Foundation

/// Only the visible menu page is persisted. This never enables a feature or loads a model.
enum MenuBarTask: String, CaseIterable, Identifiable, Hashable {
    case completion, learning
    var id: String { rawValue }
    var label: String {
        switch self {
        case .completion: String(localized: "Autocomplete")
        case .learning: String(localized: "Language Learning", table: "Learning")
        }
    }
}

/// A measured page, rather than a proposed native window frame. The popover controller is the
/// only consumer and the only object allowed to change the container's size.
struct MenuBarContentMeasurement: Equatable {
    let page: MenuBarTask
    let size: CGSize
}

/// Window-local UI state, retained by MenuBarController for the app session. Settings/services
/// remain app-owned; this object only remembers the selected page and coordinates its opacity.
/// Each new selection cancels the old fade, and a matching measured layout reveals the new body.
@MainActor
final class MenuBarPresentationModel: ObservableObject {
    static let width = MenuBarPopoverLayout.width
    @Published private(set) var selectedTask: MenuBarTask
    @Published private(set) var displayedTask: MenuBarTask
    @Published private(set) var pageVisible = true
    @Published private(set) var reduceMotion = false
    @Published var maximumLearningHeight: CGFloat = 440
    var onMeasure: ((MenuBarContentMeasurement) -> Void)?
    var onDismiss: (() -> Void)?
    private let defaults: UserDefaults
    private var transition: Task<Void, Never>?
    private var isPresented = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let page = defaults.string(forKey: "menuBarTask").flatMap(MenuBarTask.init(rawValue:)) ?? .completion
        selectedTask = page; displayedTask = page
    }

    deinit { transition?.cancel() }

    func select(_ page: MenuBarTask) {
        guard selectedTask != page else { return }
        transition?.cancel(); transition = nil
        selectedTask = page
        defaults.set(page.rawValue, forKey: "menuBarTask")
        guard isPresented, !reduceMotion, displayedTask != page else {
            displayedTask = page; pageVisible = true
            return
        }
        pageVisible = false
        transition = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !Task.isCancelled, self.selectedTask == page else { return }
            self.transition = nil
            self.displayedTask = page
            // Stay transparent until the controller has fitted this exact page's measured size.
        }
    }

    func didFit(_ page: MenuBarTask) {
        guard page == selectedTask, page == displayedTask else { return }
        pageVisible = true
    }

    func setPresented(_ value: Bool) {
        isPresented = value
        if !value { settle() }
    }

    func setReduceMotion(_ value: Bool) {
        guard value != reduceMotion else { return }
        reduceMotion = value
        if value { settle() }
    }

    func dismiss() { onDismiss?() }

    private func settle() {
        transition?.cancel(); transition = nil
        displayedTask = selectedTask
        pageVisible = true
    }
}
