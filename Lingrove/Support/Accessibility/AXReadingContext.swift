import ApplicationServices
import Foundation

/// A read-only, bounded marker adapter for explicit reading lookups. The selection reader owns
/// its opaque marker receipt; only text and exact local offsets leave this synchronous boundary.
/// No document-start/end queries or clipboard actions are used to obtain surrounding context.
@MainActor
enum AXReadingContext {
    struct Window {
        let text: String
        let range: NSRange
        let complete: Bool
        let method: String
    }

    static func selection(on element: AXUIElement) -> CFTypeRef? {
        value("AXSelectedTextMarkerRange", on: element)
    }

    static func matches(_ saved: CFTypeRef, on element: AXUIElement) -> Bool {
        guard let current = selection(on: element),
              let left = AXHelper.textMarkerEndpoints(from: saved),
              let right = AXHelper.textMarkerEndpoints(from: current) else { return false }
        return CFEqual(left.start, right.start) && CFEqual(left.end, right.end)
    }

    static func read(on element: AXUIElement, expected: String, deadline: ContinuousClock.Instant) -> Window? {
        guard ContinuousClock.now < deadline,
              let receipt = selection(on: element), let selected = AXHelper.textMarkerEndpoints(from: receipt),
              expected.utf16.count <= LearningReadingContextPolicy.maximumSelectionUTF16 else { return nil }
        // Browser sentence/paragraph markers cross inline DOM nodes without losing the occurrence.
        // A length query precedes every string query so a huge paragraph cannot become a page dump.
        var isolated: Window?
        let queries: [(String, String?)] = [
            ("AXSentenceTextMarkerRangeForTextMarker", nil),
            ("AXParagraphTextMarkerRangeForTextMarker", nil),
            ("AXPreviousSentenceStartTextMarkerForTextMarker", "AXNextSentenceEndTextMarkerForTextMarker"),
            ("AXPreviousParagraphStartTextMarkerForTextMarker", "AXNextParagraphEndTextMarkerForTextMarker")
        ]
        for query in queries {
            guard ContinuousClock.now < deadline else { return nil }
            guard let candidate = candidate(query, selected: selected, on: element),
                  let window = candidateWindow(candidate, selection: receipt, expected: expected, on: element, deadline: deadline),
                  matches(receipt, on: element) else { continue }
            if isUseful(window, expected: expected) { return window }
            isolated = window
        }
        if let window = nearbyWindow(selected: selected, receipt: receipt, expected: expected, on: element, deadline: deadline) {
            return window
        }
        return isolated.map { .init(text: $0.text, range: $0.range, complete: false, method: "marker-fragment") }
    }

    private static func nearbyWindow(selected: (start: AXTextMarker, end: AXTextMarker), receipt: CFTypeRef,
                                     expected: String, on element: AXUIElement, deadline: ContinuousClock.Instant) -> Window? {
        guard ContinuousClock.now < deadline,
              let before = walk(from: selected.start, forward: false, on: element, deadline: deadline),
              let after = walk(from: selected.end, forward: true, on: element, deadline: deadline),
              let windowRange = markerRange(before, after, on: element),
              let window = candidateWindow(windowRange, selection: receipt, expected: expected, on: element,
                  deadline: deadline, complete: false), matches(receipt, on: element) else { return nil }
        return window
    }

    /// Chromium can confine a direct sentence query to an inline span. Boundary-marker pairs
    /// provide the enclosing paragraph there; both paths still undergo the same length/offset proof.
    private static func candidate(_ query: (String, String?), selected: (start: AXTextMarker, end: AXTextMarker),
                                  on element: AXUIElement) -> CFTypeRef? {
        guard let next = query.1 else { return parameter(query.0, selected.start, on: element) }
        // Boundary queries at an exact paragraph edge may jump to the neighbouring paragraph.
        // Query from just inside the selection, then prove the resulting range encloses it.
        let insideStart = parameter("AXNextTextMarkerForTextMarker", selected.start, on: element) ?? selected.start
        let insideEnd = parameter("AXPreviousTextMarkerForTextMarker", selected.end, on: element) ?? selected.end
        guard let start = parameter(query.0, insideStart, on: element),
              let end = parameter(next, insideEnd, on: element) else { return nil }
        return parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray, on: element)
    }

    private static func candidateWindow(_ candidate: CFTypeRef, selection: CFTypeRef, expected: String,
                                        on element: AXUIElement, deadline: ContinuousClock.Instant,
                                        complete: Bool = true) -> Window? {
        guard ContinuousClock.now < deadline, let bounds = AXHelper.textMarkerEndpoints(from: candidate),
              let selected = AXHelper.textMarkerEndpoints(from: selection),
              let beforeRange = markerRange(bounds.start, selected.start, on: element),
              let afterRange = markerRange(selected.end, bounds.end, on: element),
              let beforeLength = length(beforeRange, on: element), let afterLength = length(afterRange, on: element),
              beforeLength <= 512, afterLength <= 512, let total = length(candidate, on: element),
              total == beforeLength + expected.utf16.count + afterLength,
              total <= LearningReadingContextPolicy.maximumSelectionUTF16 + 1_024,
              ContinuousClock.now < deadline,
              let before = string(beforeRange, maximum: 512, on: element),
              ContinuousClock.now < deadline,
              let target = string(selection, maximum: LearningReadingContextPolicy.maximumSelectionUTF16, on: element),
              ContinuousClock.now < deadline, let after = string(afterRange, maximum: 512, on: element),
              target.utf16.elementsEqual(expected.utf16), ContinuousClock.now < deadline,
              let whole = string(candidate, maximum: total, on: element),
              whole.utf16.elementsEqual((before + target + after).utf16) else { return nil }
        return .init(text: whole, range: NSRange(location: before.utf16.count, length: target.utf16.count),
            complete: complete, method: complete ? "marker-context" : "marker-window")
    }

    /// A host lacking sentence ranges may still expose adjacent markers. Cap both calls and text
    /// length; a partial walk is useful evidence and must remain explicitly a context fragment.
    private static func walk(from start: AXTextMarker, forward: Bool, on element: AXUIElement,
                             deadline: ContinuousClock.Instant) -> AXTextMarker? {
        var current = start
        for _ in 0..<96 {
            guard ContinuousClock.now < deadline else { break }
            let name = forward ? "AXNextTextMarkerForTextMarker" : "AXPreviousTextMarkerForTextMarker"
            guard let nextValue = parameter(name, current, on: element), CFGetTypeID(nextValue) == AXTextMarkerGetTypeID() else { break }
            // CF type verification above makes this borrowed cast safe; ARC retains the marker
            // through the bounded query and nothing interprets its browser-private bytes.
            let next = unsafeBitCast(nextValue, to: AXTextMarker.self)
            guard !CFEqual(next, current), let span = markerRange(start, next, on: element),
                  let count = length(span, on: element), count <= 512 else { break }
            current = next
        }
        return current
    }

    private static func isUseful(_ window: Window, expected: String) -> Bool {
        terminal(expected) || window.text.trimmingCharacters(in: .whitespacesAndNewlines)
            != expected.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func terminal(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".!?。！？:：".contains($0) } == true
    }

    private static func markerRange(_ start: AXTextMarker, _ end: AXTextMarker, on element: AXUIElement) -> CFTypeRef? {
        parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray, on: element)
    }
    private static func length(_ range: CFTypeRef, on element: AXUIElement) -> Int? {
        guard let count = parameter("AXLengthForTextMarkerRange", range, on: element) as? NSNumber,
              count.intValue >= 0 else { return nil }
        return count.intValue
    }
    private static func string(_ range: CFTypeRef, maximum: Int, on element: AXUIElement) -> String? {
        guard let count = length(range, on: element), count <= maximum else { return nil }
        if count == 0 { return "" }
        guard let text = parameter("AXStringForTextMarkerRange", range, on: element) as? String,
              text.utf16.count == count else { return nil }
        return text
    }
    private static func value(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private static func parameter(_ name: String, _ argument: CFTypeRef, on element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &result) == .success else { return nil }
        return result
    }
}
