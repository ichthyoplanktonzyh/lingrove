import CoreGraphics

/// Screen-coordinate placement for the two expression windows. Inline input follows the host's
/// measured baseline; expanded input stays below its caret. Neither path asks the host to reflow.
nonisolated enum ExpressionAssistLayout {
    /// One layout pass freezes the host's caret and both text engines' baseline measurements.
    struct Anchor {
        let caret: CGRect
        let hostBaseline: CGFloat
        let nativeBaseline: CGFloat
    }

    /// Every spacing and size used by the expression windows and candidate rows. Keeping them in
    /// one pure namespace means the panel controller only *applies* geometry; a visual tweak is a
    /// one-line change here instead of a hunt through hard-coded frames in AppKit code.
    enum Metrics {
        /// Widest the input, candidate and failure windows grow; long text wraps instead.
        static let maxPanelWidth: CGFloat = 380
        /// Distance kept from the visible screen edges when clamping a panel width.
        static let screenMargin: CGFloat = 10
        /// Inline (quiet) input falls back to the framed style below this much room to the right.
        static let minInlineRoom: CGFloat = 140
        static let minInputWidth: CGFloat = 160
        /// Inner padding of the framed input; the quiet input has none so text sits on the host line.
        static let inputPadding: CGFloat = 8
        static let minInputHeight: CGFloat = 50
        static let maxInputHeight: CGFloat = 180
        /// Gap between the host caret and a framed input placed below it.
        static let caretGap: CGFloat = 5
        /// Gap between the input window and the candidate window.
        static let panelGap: CGFloat = 4
        static let maxCandidateHeight: CGFloat = 320
        static let cornerRadius: CGFloat = 8
        /// Horizontal/vertical inset of candidate-panel content from its rounded edge.
        static let contentInset: CGFloat = 8
        static let rowInset: CGFloat = 4
        static let rowSpacing: CGFloat = 3
        static let rowCornerRadius: CGFloat = 5
        static let rowVerticalPadding: CGFloat = 5
        /// Column reserved on the left of each row for the ↵ selection marker.
        static let rowLeading: CGFloat = 21
        static let rowTrailing: CGFloat = 7
        static let footerHeight: CGFloat = 24
        static let statusIconSize: CGFloat = 14
        static let failureSpacing: CGFloat = 8

        /// Panels never exceed the visible screen minus margins, so small displays still fit.
        static func panelWidth(screen: CGRect) -> CGFloat {
            min(maxPanelWidth, screen.width - screenMargin * 2)
        }
    }

    static func input(anchor: Anchor, size: CGSize, screen: CGRect, inline: Bool) -> CGRect? {
        let caret = anchor.caret
        guard finite(caret), finite(screen), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width <= screen.width, size.height <= screen.height else { return nil }
        let originX = caret.minX
        let originY = inline
            ? caret.maxY - anchor.hostBaseline + anchor.nativeBaseline - size.height
            : caret.minY - Metrics.caretGap - size.height
        return CGRect(x: min(max(originX, screen.minX), screen.maxX - size.width),
            y: min(max(originY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }

    static func candidates(input: CGRect, size: CGSize, screen: CGRect) -> CGRect? {
        guard finite(input), finite(screen), size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite, size.width <= screen.width, size.height <= screen.height else { return nil }
        let originX = min(max(input.minX, screen.minX), screen.maxX - size.width)
        let below = CGRect(x: originX, y: input.minY - Metrics.panelGap - size.height, width: size.width, height: size.height)
        if screen.contains(below) { return below }
        let above = CGRect(x: originX, y: input.maxY + Metrics.panelGap, width: size.width, height: size.height)
        return screen.contains(above) ? above : nil
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
