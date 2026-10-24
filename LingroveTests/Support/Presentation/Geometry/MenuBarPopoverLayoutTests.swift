import CoreGraphics
import Testing
@testable import Lingrove

struct MenuBarPopoverLayoutTests {
    @Test func fixedWidthAndBackingPixelRoundingProduceAStableTarget() {
        let size = MenuBarPopoverLayout.contentSize(height: 367.1, scale: 2)
        #expect(size == CGSize(width: 340, height: 367.5))
        #expect(MenuBarPopoverLayout.contentSize(height: 367.5, scale: 2) == size)
        #expect(MenuBarPopoverLayout.contentSize(height: 634, scale: 1) == CGSize(width: 340, height: 634))
    }

    @Test(arguments: [CGFloat.zero, -1, CGFloat.nan, CGFloat.infinity])
    func invalidHeightsCannotResizeThePopover(_ height: CGFloat) {
        #expect(MenuBarPopoverLayout.contentSize(height: height, scale: 2) == nil)
    }
}
