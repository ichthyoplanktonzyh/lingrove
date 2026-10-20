import SwiftUI

/// Dictionary component words can be wider than their card. Measure them again with the
/// available width so text wraps without overflowing the window. Callers
/// pin this layout to left-to-right coordinates; `rightToLeft` describes the content and is the
/// only direction that should mirror the manually placed frames.
struct LearningTextFlowLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat
    var rightToLeft = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = result.frames[index]
            let originX = rightToLeft ? bounds.maxX - frame.maxX : bounds.minX + frame.minX
            subview.place(at: CGPoint(x: originX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let idealWidth = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let width = max((proposedWidth?.isFinite == true ? proposedWidth : nil) ?? idealWidth, 1)
        var frames: [CGRect] = []
        var rowStart = 0
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var rowHeight: CGFloat = 0
        func finishRow() {
            for index in rowStart..<frames.count { frames[index].origin.y += (rowHeight - frames[index].height) / 2 }
            rowStart = frames.count
            offsetX = 0
            offsetY += max(rowHeight, 22) + rowSpacing
            rowHeight = 0
        }
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if offsetX > 0, offsetX + spacing + size.width > width { finishRow() }
            if offsetX > 0 { offsetX += spacing }
            frames.append(CGRect(origin: CGPoint(x: offsetX, y: offsetY), size: size))
            offsetX += size.width
            rowHeight = max(rowHeight, size.height)
        }
        for index in rowStart..<frames.count { frames[index].origin.y += (rowHeight - frames[index].height) / 2 }
        return (CGSize(width: width, height: offsetY + rowHeight), frames)
    }
}

/// Measures the bounded card rectangle independently of its scroll content. Zero
/// is an initial layout sentinel, never a replacement for an already usable viewport height.
nonisolated struct LearningCardSizePreference: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
