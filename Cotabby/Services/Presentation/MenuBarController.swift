import AppKit
import Logging
import SwiftUI

/// The app's single menu presentation owner, retained by AppDelegate. It owns NSStatusItem and
/// NSPopover; the hosted pages borrow the existing dependency graph. Only this object assigns
/// popover.contentSize, so SwiftUI measures content without competing to resize a native window.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let presentation: MenuBarPresentationModel
    private let popover = NSPopover()
    private let contentController: MenuBarContentController
    private let statusLabel: AnyView
    private let onPresent: () -> Void
    private var statusItem: NSStatusItem?
    private var labelHost: MenuBarStatusHostingView?
    private var layoutTask: Task<Void, Never>?
    /// AppKit marks isShown false before its closing animation finishes. Keep that interval
    /// explicit so a new opening cannot be reset by the previous didClose notification.
    private enum Phase { case hidden, shown, closing }
    private var phase = Phase.hidden
    private var reopenAfterClose = false
    private var pendingMeasurement: MenuBarContentMeasurement?
    private var accessibilityObserver: NSObjectProtocol?

    init(presentation: MenuBarPresentationModel, content: AnyView, statusLabel: AnyView,
         onPresent: @escaping () -> Void) {
        self.presentation = presentation
        self.statusLabel = statusLabel
        self.onPresent = onPresent
        contentController = MenuBarContentController(content: content)
        super.init()
        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.delegate = self
        updateMotionPreference()
        presentation.onDismiss = { [weak self] in self?.close() }
        presentation.onMeasure = { [weak self] in self?.scheduleLayout($0) }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotionPreference() }
        }
    }

    deinit {
        layoutTask?.cancel()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    func setVisible(_ visible: Bool) {
        if !visible {
            close()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil; labelHost = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 30)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(toggle)
        button.setAccessibilityLabel(String(localized: "Lingrove", table: "Learning"))
        button.toolTip = String(localized: "Lingrove", table: "Learning")
        let label = statusLabel.onPreferenceChange(MenuBarStatusAccessibilityKey.self) { [weak self] label in
            if !label.isEmpty { self?.statusItem?.button?.setAccessibilityLabel(label) }
        }.background(GeometryReader { geometry in
            Color.clear.preference(key: MenuBarStatusWidthKey.self, value: geometry.size.width)
        }).onPreferenceChange(MenuBarStatusWidthKey.self) { [weak self] width in
            // Status text can grow after acceptance. Defer constraint changes out of SwiftUI's
            // current layout pass; a removed item's queued update must not recreate the item.
            Task { @MainActor [weak self] in self?.updateStatusWidth(width) }
        }
        let host = MenuBarStatusHostingView(rootView: AnyView(label))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        labelHost = host
        updateStatusWidth(host.fittingSize.width)
    }

    var isShown: Bool { popover.isShown }
    var contentSize: CGSize { popover.contentSize }

    @objc func toggle() {
        if phase == .closing {
            reopenAfterClose.toggle()
            return
        }
        reopenAfterClose = false
        if popover.isShown { close(); return }
        guard let button = statusItem?.button else { return }
        let screenHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        presentation.maximumLearningHeight = max(160, min(440, screenHeight - 290))
        updateMotionPreference()
        onPresent()
        // Initial fit precedes showing the popover; later natural-height reports use the same
        // sizing entry point. No observer or callback writes the popover's underlying NSWindow.
        let measured = contentController.measure()
        applySize(measured.height, animated: false)
        phase = .shown
        presentation.setPresented(true)
        popover.animates = !presentation.reduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        reopenAfterClose = false
        if popover.isShown { phase = .closing }
        retireLayout()
        popover.performClose(nil)
        statusItem?.button?.highlight(false)
    }

    func shutdown() {
        setVisible(false)
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
        presentation.onDismiss = nil; presentation.onMeasure = nil
    }

    func popoverWillClose(_ notification: Notification) {
        // This path also covers outside clicks and Escape, which bypass our close() action.
        phase = .closing
        retireLayout()
    }

    func popoverDidClose(_ notification: Notification) {
        phase = .hidden
        retireLayout()
        statusItem?.button?.highlight(false)
        if reopenAfterClose {
            Task { @MainActor [weak self] in
                guard let self, self.phase == .hidden, self.reopenAfterClose else { return }
                self.reopenAfterClose = false
                self.toggle()
            }
        }
    }

    private func retireLayout() {
        layoutTask?.cancel(); layoutTask = nil; pendingMeasurement = nil
        presentation.setPresented(false)
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    private func updateStatusWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0, let statusItem else { return }
        let length = ceil(width) + 12
        if abs(statusItem.length - length) > 0.5 { statusItem.length = length }
    }

    private func updateMotionPreference() {
        presentation.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        popover.animates = !presentation.reduceMotion
    }

    private func scheduleLayout(_ measurement: MenuBarContentMeasurement) {
        // Reject stale reports before coalescing: an old page must not overwrite a pending
        // valid report and leave the current body permanently transparent.
        guard phase == .shown, measurement.page == presentation.displayedTask,
              measurement.page == presentation.selectedTask else { return }
        pendingMeasurement = measurement
        guard layoutTask == nil else { return }
        layoutTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.layoutTask = nil
            guard let measurement = self.pendingMeasurement else { return }
            self.pendingMeasurement = nil
            // Closing can publish a settled page while the native close animation is still
            // visible. Those late geometry reports must not restart a resize during dismissal.
            guard self.phase == .shown, self.popover.isShown, measurement.page == self.presentation.displayedTask,
                  measurement.page == self.presentation.selectedTask else { return }
            self.applySize(measurement.size.height, animated: !self.presentation.reduceMotion)
            self.presentation.didFit(measurement.page)
        }
    }

    private func applySize(_ height: CGFloat, animated: Bool) {
        let scale = statusItem?.button?.window?.backingScaleFactor ?? 2
        guard let size = MenuBarPopoverLayout.contentSize(height: height, scale: scale) else { return }
        guard popover.contentSize != size else { return }
        popover.animates = animated
        popover.contentSize = size
        CotabbyLogger.app.debug("Menu popover content fitted", metadata: [
            "stage": "menu-popover-layout", "page": .string(presentation.displayedTask.rawValue),
            "height": .stringConvertible(size.height), "animated": .stringConvertible(animated)
        ])
    }
}

/// One stable parent separates the popover viewport from the child's natural SwiftUI height.
/// The hosting view stays pinned to the top at its intrinsic height while the viewport animates,
/// so controls never stretch or vertically recenter. Only the parent clips during shrinking.
@MainActor
private final class MenuBarContentController: NSViewController {
    private let host: NSHostingController<AnyView>

    init(content: AnyView) {
        host = NSHostingController(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.widthAnchor.constraint(equalToConstant: MenuBarPresentationModel.width)
        ])
    }

    func measure() -> CGSize {
        loadViewIfNeeded()
        return host.sizeThatFits(in: CGSize(width: MenuBarPresentationModel.width, height: 10_000))
    }
}

/// Clicks belong to the native status button, even over the hosted SwiftUI icon or word count.
private final class MenuBarStatusHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct MenuBarStatusWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
