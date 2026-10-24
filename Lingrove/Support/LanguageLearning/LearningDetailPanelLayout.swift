import CoreGraphics

/// Places the child next to its sentence card while avoiding the completion and caret too.
/// Keeping this pure makes screen-edge behavior testable without changing either parent window.
nonisolated enum LearningDetailPanelLayout {
    /// An insertion caret marks a line the user is still reading across, not just a 1–2pt
    /// forbidden pixel. Explicit selection/OCR rectangles already describe their protected area.
    static func protectedTextRect(_ caret: CGRect, screen: CGRect) -> CGRect {
        guard !caret.isEmpty, caret.width <= 4, caret.height <= 80 else { return caret }
        return CGRect(x: screen.minX, y: caret.minY, width: screen.width, height: caret.height)
    }

    static func frame(parent: CGRect, anchorY: CGFloat, size: CGSize, screen: CGRect, obstacles: [CGRect],
                      preferred: CGRect? = nil) -> CGRect? {
        guard [size.width, size.height, anchorY, screen.minX, screen.minY, screen.width, screen.height,
               parent.minX, parent.minY, parent.width, parent.height].allSatisfy(\.isFinite),
              size.width > 0, size.height > 0, size.width <= screen.width, size.height <= screen.height else { return nil }
        let gap: CGFloat = 8
        let blocked = ([parent] + obstacles).filter {
            [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) && !$0.isEmpty
        }.map { $0.insetBy(dx: -gap, dy: -gap) }
        let originY = min(max(anchorY - size.height, screen.minY), screen.maxY - size.height)
        let originX = min(max(parent.minX, screen.minX), screen.maxX - size.width)
        var origins = [CGPoint(x: parent.maxX + gap, y: originY),
                       CGPoint(x: parent.minX - gap - size.width, y: originY),
                       CGPoint(x: originX, y: parent.minY - gap - size.height),
                       CGPoint(x: originX, y: parent.maxY + gap)]
        if let preferred, [preferred.minX, preferred.maxY].allSatisfy(\.isFinite) {
            // Keep the top edge and side chosen for this lookup. A taller definition may need
            // a vertical clamp near the screen edge, but must not gratuitously switch sides.
            let top = min(max(preferred.maxY - size.height, screen.minY), screen.maxY - size.height)
            origins.insert(CGPoint(x: preferred.minX, y: top), at: 0)
        }
        let horizontal = [originX, screen.minX, screen.maxX - size.width] + blocked.flatMap { [$0.maxX, $0.minX - size.width] }
        let vertical = [originY, screen.minY, screen.maxY - size.height] + blocked.flatMap { [$0.maxY, $0.minY - size.height] }
        for offsetX in horizontal {
            for offsetY in vertical { origins.append(CGPoint(x: offsetX, y: offsetY)) }
        }
        return origins.lazy.map { CGRect(origin: $0, size: size) }.first { candidate in
            screen.contains(candidate) && !blocked.contains { $0.intersects(candidate) }
        }
    }
}
