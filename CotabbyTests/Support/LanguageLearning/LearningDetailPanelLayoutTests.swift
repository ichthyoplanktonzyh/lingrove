import CoreGraphics
import Testing
@testable import Cotabby

struct LearningDetailPanelLayoutTests {
    @Test func tallCardDoesNotCoverTheTextBesideAnInsertionCaret() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let parent = CGRect(x: 200, y: 350, width: 480, height: 200)
        let caret = CGRect(x: 200, y: 300, width: 2, height: 20)
        let line = LearningDetailPanelLayout.protectedTextRect(caret, screen: screen)
        let frame = try #require(LearningDetailPanelLayout.frame(parent: parent, anchorY: 550,
            size: CGSize(width: 340, height: 440), screen: screen, obstacles: [line]))
        #expect(!frame.intersects(line.insetBy(dx: -8, dy: -8)))
        let selection = CGRect(x: 200, y: 300, width: 180, height: 60)
        #expect(LearningDetailPanelLayout.protectedTextRect(selection, screen: screen) == selection)
    }

    @Test(arguments: [CGRect(x: 200, y: 300, width: 480, height: 250),
                      CGRect(x: 950, y: 300, width: 480, height: 250)])
    func sitsBesideTheParentWithoutCoveringOtherSurfaces(_ parent: CGRect) throws {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let caret = CGRect(x: parent.minX, y: parent.minY - 30, width: 2, height: 20)
        let completion = CGRect(x: parent.minX, y: 180, width: 480, height: 70)
        let frame = try #require(LearningDetailPanelLayout.frame(parent: parent, anchorY: parent.maxY,
            size: CGSize(width: 320, height: 260), screen: screen, obstacles: [caret, completion]))
        #expect(screen.contains(frame))
        #expect(!frame.intersects(parent.insetBy(dx: -8, dy: -8)))
        #expect(!frame.intersects(caret.insetBy(dx: -8, dy: -8)))
        #expect(!frame.intersects(completion.insetBy(dx: -8, dy: -8)))
    }

    @Test
    func noSpaceReturnsNoWindowInsteadOfCoveringItsParent() {
        let screen = CGRect(x: -800, y: -100, width: 800, height: 600)
        #expect(LearningDetailPanelLayout.frame(parent: screen, anchorY: screen.maxY,
            size: CGSize(width: 320, height: 260), screen: screen, obstacles: []) == nil)
    }

    @Test func sourceGrowthKeepsItsSideAndTopEdgeAndNewObstaclesStillWin() throws {
        let screen = CGRect(x: -1_440, y: -100, width: 1_440, height: 900)
        let parent = CGRect(x: -1_000, y: 200, width: 480, height: 200)
        let small = try #require(LearningDetailPanelLayout.frame(parent: parent, anchorY: 650,
            size: CGSize(width: 340, height: 120), screen: screen, obstacles: []))
        let large = try #require(LearningDetailPanelLayout.frame(parent: parent, anchorY: 650,
            size: CGSize(width: 340, height: 440), screen: screen, obstacles: [], preferred: small))
        #expect(large.minX == small.minX && large.maxY == small.maxY)
        let moved = try #require(LearningDetailPanelLayout.frame(parent: parent, anchorY: 650,
            size: large.size, screen: screen, obstacles: [large], preferred: large))
        #expect(!moved.intersects(large.insetBy(dx: -8, dy: -8)))
    }
}
