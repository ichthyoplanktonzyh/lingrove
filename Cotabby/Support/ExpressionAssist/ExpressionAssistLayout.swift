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

    static func input(anchor: Anchor, size: CGSize, screen: CGRect, inline: Bool) -> CGRect? {
        let caret = anchor.caret
        guard finite(caret), finite(screen), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width <= screen.width, size.height <= screen.height else { return nil }
        let originX = caret.minX
        let originY = inline ? caret.maxY - anchor.hostBaseline + anchor.nativeBaseline - size.height : caret.minY - 5 - size.height
        return CGRect(x: min(max(originX, screen.minX), screen.maxX - size.width),
            y: min(max(originY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }

    static func candidates(input: CGRect, size: CGSize, screen: CGRect) -> CGRect? {
        guard finite(input), finite(screen), size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite, size.width <= screen.width, size.height <= screen.height else { return nil }
        let originX = min(max(input.minX, screen.minX), screen.maxX - size.width)
        let below = CGRect(x: originX, y: input.minY - 4 - size.height, width: size.width, height: size.height)
        if screen.contains(below) { return below }
        let above = CGRect(x: originX, y: input.maxY + 4, width: size.width, height: size.height)
        return screen.contains(above) ? above : nil
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
