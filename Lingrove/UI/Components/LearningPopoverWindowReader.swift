import AppKit
import SwiftUI

/// A zero-size background observes only the window hosting the popover's real content.
/// It never activates a window or handles input; the panel retains ownership of dismissal.
struct LearningPopoverWindowReader: NSViewRepresentable {
    let registry: LearningPopupWindowRegistry?

    func makeNSView(context: Context) -> LearningPopoverReadingView {
        let view = LearningPopoverReadingView(frame: .zero)
        view.registry = registry
        return view
    }
    func updateNSView(_ view: LearningPopoverReadingView, context: Context) {
        if view.registry !== registry { view.registry = registry }
    }
    static func dismantleNSView(_ view: LearningPopoverReadingView, coordinator: ()) { view.registry = nil }
}

@MainActor
final class LearningPopoverReadingView: NSView {
    private let registrationID = UUID()
    var registry: LearningPopupWindowRegistry? {
        didSet {
            oldValue?.update(nil, for: registrationID)
            registry?.update(window, for: registrationID)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registry?.update(window, for: registrationID)
    }
}
