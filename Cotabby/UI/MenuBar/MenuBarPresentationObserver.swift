import AppKit
import SwiftUI

/// Observes the AppKit window that backs SwiftUI's menu-bar panel.
///
/// `MenuBarExtra` may keep its SwiftUI content alive between openings, which means `onAppear` is
/// not a perfect "the user opened the menu" signal. This tiny bridge watches the real `NSWindow`
/// instead and calls `onPresent` whenever the panel becomes key or visible again.
struct MenuBarPresentationObserver: NSViewRepresentable {
    let onPresent: () -> Void

    func makeNSView(context: Context) -> MenuBarPresentationTrackingView {
        let view = MenuBarPresentationTrackingView()
        view.onPresent = onPresent
        return view
    }

    func updateNSView(_ nsView: MenuBarPresentationTrackingView, context: Context) {
        nsView.onPresent = onPresent
    }
}

/// Invisible AppKit view that attaches window notifications to a SwiftUI menu-bar panel.
///
/// The view deliberately reports only visibility/key-window transitions. The permission manager
/// already owns periodic polling; this bridge only covers the UI lifecycle edge where reopening
/// the menu should force one immediate permission read.
final class MenuBarPresentationTrackingView: NSView {
    var onPresent: (() -> Void)?

    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?

    deinit {
        removeObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeCurrentWindow()
        refreshIfVisible()
    }

    func refreshIfVisible() {
        guard let window, window.isVisible || window.occlusionState.contains(.visible) else {
            return
        }

        guard refreshTask == nil else { return }
        // AppKit can attach this view while SwiftUI is updating its tree. Defer publication
        // until that transaction finishes, coalescing key/visibility notifications from one open.
        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            guard let window = self.window,
                  window.isVisible || window.occlusionState.contains(.visible) else { return }
            self.onPresent?()
        }
    }

    private func observeCurrentWindow() {
        guard observedWindow !== window else {
            return
        }

        removeObservers()
        observedWindow = window

        guard let window else {
            return
        }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refreshIfVisible()
            },
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refreshIfVisible()
            }
        ]
    }

    private func removeObservers() {
        refreshTask?.cancel()
        refreshTask = nil
        observers.forEach(NotificationCenter.default.removeObserver(_:))
        observers.removeAll()
        observedWindow = nil
    }
}
