import CoreGraphics
import Foundation

/// Pure selection-location evidence shared by capture and OCR alignment. The coordinator binds
/// a gesture to one AX receipt; this policy verifies that binding and compares OCR's first/last
/// word boxes to the actual gesture endpoints. No nearest-word or presentation-anchor fallback
/// is allowed. Values are borrowed for one frozen frame and never change the selected text.
nonisolated enum LearningReadingGesturePolicy {
    static func searchBounds(_ selection: LearningReadingSelection, within region: CGRect? = nil,
                             now: Date? = nil) -> CGRect? {
        let gesture = gestureBounds(selection, within: region, now: now)
        if let bounds = selection.selectionBounds, LearningReadingSelectionOCRPolicy.valid(bounds) {
            if let region, !region.contains(bounds) { return gesture }
            // Some hosts return a whole paragraph/page box for a word. A bound recent gesture
            // is stronger location evidence there; keep the raw AX box intact as a receipt.
            if let gesture, bounds.width > gesture.width * 3 || bounds.height > gesture.height * 3 { return gesture }
            return bounds
        }
        return gesture
    }

    private static func gestureBounds(_ selection: LearningReadingSelection, within region: CGRect?, now: Date?) -> CGRect? {
        guard selection.source == .selection, let gesture = selection.gesture,
              gesture.selectionID == selection.id, finite(gesture.start), finite(gesture.end),
              (0...1).contains(selection.capturedAt.timeIntervalSince(gesture.completedAt)),
              now.map({ (0...8).contains($0.timeIntervalSince(gesture.completedAt)) }) ?? true,
              gesture.kind != .drag || hypot(gesture.end.x - gesture.start.x, gesture.end.y - gesture.start.y) > 3
        else { return nil }
        if let region, !region.contains(gesture.start) || !region.contains(gesture.end) { return nil }
        let box = CGRect(x: min(gesture.start.x, gesture.end.x), y: min(gesture.start.y, gesture.end.y),
            width: abs(gesture.start.x - gesture.end.x), height: abs(gesture.start.y - gesture.end.y)).insetBy(dx: -12, dy: -12)
        return region.map { box.intersection($0) } ?? box
    }

    /// A double click must hit the selected OCR unit. A drag must bracket its first and last
    /// words in reading order, in either direction; a same-spelled neighbour cannot win merely
    /// because its box intersects the broad multi-line drag envelope.
    static func agrees(_ gesture: LearningReadingGesture, first: CGRect, last: CGRect) -> Bool {
        guard LearningReadingSelectionOCRPolicy.valid(first), LearningReadingSelectionOCRPolicy.valid(last) else { return false }
        if gesture.kind == .doubleClick {
            return first == last && first.insetBy(dx: -3, dy: -3).contains(gesture.end)
        }
        let tolerance = min(12, max(5, min(first.height, last.height) * 0.5))
        func brackets(_ start: CGPoint, _ end: CGPoint) -> Bool {
            abs(start.x - first.minX) <= tolerance && abs(end.x - last.maxX) <= tolerance &&
                start.y >= first.minY - tolerance && start.y <= first.maxY + tolerance &&
                end.y >= last.minY - tolerance && end.y <= last.maxY + tolerance
        }
        return brackets(gesture.start, gesture.end) || brackets(gesture.end, gesture.start)
    }

    private static func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
}
