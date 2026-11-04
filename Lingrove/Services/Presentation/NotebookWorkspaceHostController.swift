import AppKit
import SwiftUI

/// The notebook window retains this native split host. Each destination has its own hosting
/// controller, so the original corpus keeps SwiftUI's selection, filters, graph and toolbar
/// state while another destination is visible. Every destination inherits the owning window's
/// appearance; navigation never changes the window or another subtree's resolved color scheme.
/// Removing a child view also retires its SwiftUI appearance-bound work.
@MainActor
final class NotebookWorkspaceHostController: NSSplitViewController {
    private let sidebar: NSViewController
    private let content = NSViewController()
    // A destination without actions still occupies the window's existing toolbar region.
    // Removing the toolbar changes AppKit's content viewport and moves the entire split view.
    private let navigationToolbar = NSToolbar(identifier: "LingroveNotebookNavigation")
    private(set) var visibleController: NSViewController?
    private weak var corpusToolbarOwner: NSViewController?
    private var corpusToolbar: NSToolbar?
    private var visibleHasCorpusToolbar = false

    init(sidebar: NotebookWorkspaceSidebar) {
        self.sidebar = NSHostingController(rootView: sidebar)
        navigationToolbar.displayMode = .iconOnly
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// An embedded NSHostingController defaults to no scene bridging; only a window's direct
    /// content controller defaults to all. Explicit toolbar bridging preserves the original
    /// corpus's SwiftUI toolbar without giving a child permission to replace the window title.
    /// Only the visible destination is attached, so hidden roots cannot contribute toolbar items.
    static func destinationHost<Content: View>(rootView: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: rootView)
        controller.sceneBridgingOptions = [.toolbars]
        // The native split view supplies all four edges. An asynchronously loaded page must
        // not publish a different intrinsic minimum back into the window's geometry.
        controller.sizingOptions = []
        // A nil local appearance follows the native parent even when the window's appearance
        // changes while this destination is detached. Views supply semantic colors, not a theme.
        controller.view.appearance = nil
        return controller
    }

    override func loadView() {
        super.loadView()
        content.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        let destinationItem = NSSplitViewItem(viewController: content)
        // The untouched corpus requires 760 points; leave room for its existing split layout
        // rather than shrinking the browser or replacing its toolbar to fit the new sidebar.
        destinationItem.minimumThickness = 780
        addSplitViewItem(sidebarItem)
        addSplitViewItem(destinationItem)
    }

    func show(_ controller: NSViewController, preservingCorpusToolbar: Bool = false) {
        loadViewIfNeeded()
        guard visibleController !== controller else { return }
        let window = view.window
        if visibleHasCorpusToolbar {
            corpusToolbarOwner = visibleController
            corpusToolbar = window?.toolbar
        }
        visibleController?.view.removeFromSuperview()
        visibleController?.removeFromParent()
        // Replace corpus actions without removing the native toolbar region. Hidden corpus
        // Edit/Delete actions must not remain live on Review or Progress.
        window?.toolbar = navigationToolbar
        content.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: content.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: content.view.bottomAnchor)
        ])
        if preservingCorpusToolbar, corpusToolbarOwner === controller {
            window?.toolbar = corpusToolbar
        }
        visibleHasCorpusToolbar = preservingCorpusToolbar
        visibleController = controller
    }
}
