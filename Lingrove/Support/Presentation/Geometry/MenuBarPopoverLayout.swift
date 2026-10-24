import CoreGraphics

/// Validates measured content, not the native window frame. The menu controller supplies the
/// current display scale; backing-pixel rounding prevents fractional layout reports from
/// repeatedly restarting the popover's native resize animation.
enum MenuBarPopoverLayout {
    static let width: CGFloat = 340
    static func contentSize(height: CGFloat, scale: CGFloat) -> CGSize? {
        guard height.isFinite, height > 0, scale.isFinite, scale > 0 else { return nil }
        let rounded = (height * scale).rounded(.up) / scale
        guard rounded.isFinite else { return nil }
        return CGSize(width: width, height: rounded)
    }
}
