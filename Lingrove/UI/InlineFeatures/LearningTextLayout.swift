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

/// Shared adaptive glass chrome for floating language-learning cards (`LearningSentenceCard` and
/// `LearningDictionaryCard`). It pairs `.regularMaterial` with continuous corner curvature, a
/// subtle top-lit sheen, and an adaptive hairline border so the card separates cleanly from both
/// bright document editors and dark IDEs without shifting layout geometry.
struct LearningCardChrome: ViewModifier {
    var cornerRadius: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.045 : 0.28),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.65),
                            Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.09)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
            }
            .clipShape(shape)
    }
}

extension View {
    /// Applies the shared adaptive glass backdrop and top-lit hairline border for learning cards.
    func learningCardChrome(cornerRadius: CGFloat = 12) -> some View {
        modifier(LearningCardChrome(cornerRadius: cornerRadius))
    }
}

/// Size-neutral button style for compact toolbar icons inside floating learning cards.
/// Hovering reveals a soft rounded highlight and pressing scales the glyph down slightly on
/// pointer-down (`scaleEffect(0.92)`), while keeping the outer hit rectangle fixed so neighboring
/// controls and `NSHostingView` fitting sizes never shift.
struct LearningIconActionButtonStyle: ButtonStyle {
    var hovering = false
    var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let activeHover = hovering && isEnabled
        let activePress = configuration.isPressed && isEnabled
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(activePress ? 0.13 : (activeHover ? 0.075 : 0)))
            }
            .scaleEffect(activePress && !reduceMotion ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: activePress)
            .animation(.easeOut(duration: 0.12), value: activeHover)
    }
}
