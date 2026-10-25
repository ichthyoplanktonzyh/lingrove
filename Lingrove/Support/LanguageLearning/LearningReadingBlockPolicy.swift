import CoreGraphics

/// Chromium may expose both a paragraph and an inline span as AXGroup. Sibling layout supplies
/// a block expansion hint. Even separated siblings can be soft-wrapped inline text.
/// This hint never certifies sentence completeness; unknown/missing geometry supplies no hint.
nonisolated enum LearningReadingBlockPolicy {
    static func separates(_ frame: CGRect, before: CGRect?, after: CGRect?, first: Bool, last: Bool) -> Bool {
        guard valid(frame), before.map(valid) ?? first, after.map(valid) ?? last else { return false }
        return (before.map { $0.maxY <= frame.minY + 0.5 } ?? first) &&
            (after.map { $0.minY >= frame.maxY - 0.5 } ?? last)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.width > 1 && frame.height > 1 && frame.minX.isFinite && frame.minY.isFinite &&
            frame.width.isFinite && frame.height.isFinite
    }
}
