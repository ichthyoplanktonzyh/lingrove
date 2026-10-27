import CoreGraphics
import Foundation
import Testing
@testable import Lingrove

/// Pointer evidence is useful only when bound to the same, freshly captured native selection.
/// These tests reject stale gestures and presentation anchors without reading another app.
struct LearningReadingGesturePolicyTests {
    @Test func onlyARecentGestureBoundToThisReceiptCanReplaceMissingAXGeometry() {
        var selection = capture()
        #expect(LearningReadingGesturePolicy.searchBounds(selection) == nil)
        selection.gesture = gesture(selection.id)
        #expect(LearningReadingGesturePolicy.searchBounds(selection, now: Date(timeIntervalSince1970: 205)) != nil)
        #expect(LearningReadingGesturePolicy.searchBounds(selection, now: Date(timeIntervalSince1970: 209)) == nil)
        selection.gesture = gesture(UUID())
        #expect(LearningReadingGesturePolicy.searchBounds(selection) == nil)
        selection.gesture = gesture(selection.id, completedAt: Date(timeIntervalSince1970: 190))
        #expect(LearningReadingGesturePolicy.searchBounds(selection) == nil)
        selection.gesture = gesture(selection.id, completedAt: Date(timeIntervalSince1970: 201))
        #expect(LearningReadingGesturePolicy.searchBounds(selection) == nil)
    }

    @Test func reversedAndMultilineDragsMustBracketTheActualFirstAndLastWords() {
        let first = CGRect(x: 100, y: 100, width: 50, height: 20)
        let last = CGRect(x: 20, y: 70, width: 60, height: 20)
        for backward in [false, true] {
            let start = CGPoint(x: first.minX, y: first.midY), end = CGPoint(x: last.maxX, y: last.midY)
            let gesture = LearningReadingGesture(selectionID: UUID(), start: backward ? end : start,
                end: backward ? start : end, kind: .drag, completedAt: Date())
            #expect(LearningReadingGesturePolicy.agrees(gesture, first: first, last: last))
            #expect(!LearningReadingGesturePolicy.agrees(gesture, first: first.offsetBy(dx: 80, dy: 0), last: last))
            #expect(!LearningReadingGesturePolicy.agrees(gesture, first: first, last: last.offsetBy(dx: 0, dy: -40)))
        }
    }

    @Test func doubleClickMustHitOneUnitAndCannotSelectANearbyWord() {
        let box = CGRect(x: 100, y: 100, width: 50, height: 20)
        let point = CGPoint(x: box.midX, y: box.midY)
        let gesture = LearningReadingGesture(selectionID: UUID(), start: point, end: point, kind: .doubleClick, completedAt: Date())
        #expect(LearningReadingGesturePolicy.agrees(gesture, first: box, last: box))
        #expect(!LearningReadingGesturePolicy.agrees(gesture, first: box.offsetBy(dx: 100, dy: 0), last: box))
        #expect(!LearningReadingGesturePolicy.agrees(gesture, first: box, last: box.offsetBy(dx: 70, dy: 0)))
    }

    @Test func gestureCannotCrossTheCapturedWindowAndAXGeometryStillWins() {
        var selection = capture()
        selection.gesture = gesture(selection.id)
        #expect(LearningReadingGesturePolicy.searchBounds(selection, within: CGRect(x: 0, y: 0, width: 90, height: 90)) == nil)
        let bounds = CGRect(x: 30, y: 20, width: 50, height: 20)
        selection.selectionBounds = bounds
        #expect(LearningReadingGesturePolicy.searchBounds(selection, now: Date(timeIntervalSince1970: 1000)) == bounds)
    }

    private func capture() -> LearningReadingSelection {
        LearningReadingSelection(id: UUID(), text: "history", processIdentifier: 1, bundleIdentifier: "fixture",
            anchor: CGRect(x: 80, y: 40, width: 1, height: 18), capturedAt: Date(timeIntervalSince1970: 200.2))
    }
    private func gesture(_ id: UUID, completedAt: Date = Date(timeIntervalSince1970: 200)) -> LearningReadingGesture {
        LearningReadingGesture(selectionID: id, start: CGPoint(x: 80, y: 40), end: CGPoint(x: 160, y: 40),
            kind: .drag, completedAt: completedAt)
    }
}
