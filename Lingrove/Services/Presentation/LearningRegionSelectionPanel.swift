import AppKit

/// App-owned, short-lived region picker. Nonactivating panels cover displays only during an
/// explicit OCR command. A single continuation owns the result; cancellation closes every panel
/// before resuming, so a late mouse-up cannot submit a second screenshot or steal host focus.
@MainActor
final class LearningRegionSelectionPanel {
    private var panels: [NSPanel] = []
    private var pending: CheckedContinuation<CGRect, any Error>?
    private var revision = UUID()
    var isSelecting: Bool { pending != nil }

    func select() async throws -> CGRect {
        cancel()
        let id = UUID()
        revision = id
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                for screen in NSScreen.screens {
                    let panel = RegionWindow(
                        contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
                    panel.title = LearningReadingSource.screenshot.title
                    panel.level = .screenSaver
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.hasShadow = false
                    panel.hidesOnDeactivate = false
                    panel.isReleasedWhenClosed = false
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    panel.contentView = RegionView(
                        frame: CGRect(origin: .zero, size: screen.frame.size),
                        finished: { [weak self] rect in
                            self?.finish(rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
                        }, cancelled: { [weak self] in self?.cancel() })
                    panels.append(panel)
                    panel.orderFrontRegardless()
                }
                if panels.isEmpty { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.revision == id else { return }
                self.cancel()
            }
        }
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func finish(_ rect: CGRect) {
        guard rect.width >= 4, rect.height >= 4 else {
            cancel()
            return
        }
        complete(.success(rect))
    }

    private func complete(_ result: Result<CGRect, any Error>) {
        let continuation = pending
        pending = nil
        panels.forEach {
            $0.orderOut(nil)
            $0.contentView = nil
        }
        panels.removeAll()
        continuation?.resume(with: result)
    }
}

private final class RegionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Rendering and drag geometry stay in this disposable view; it never captures pixels or invokes
/// translation. Tracking is local to one display, making Retina and negative screen origins exact.
private final class RegionView: NSView {
    private let finished: (CGRect) -> Void
    private let cancelled: () -> Void
    private var start: CGPoint?
    private var selection = CGRect.zero
    init(frame: CGRect, finished: @escaping (CGRect) -> Void, cancelled: @escaping () -> Void) {
        self.finished = finished
        self.cancelled = cancelled
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(start.x - end.x), height: abs(start.y - end.y)
        ).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        finished(selection)
    }
    override func rightMouseDown(with event: NSEvent) { cancelled() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        let mask = NSBezierPath(rect: bounds)
        if !selection.isEmpty {
            mask.appendRect(selection)
            mask.windingRule = .evenOdd
        }
        mask.fill()
        if !selection.isEmpty {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }
}
