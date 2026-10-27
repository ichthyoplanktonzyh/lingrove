import ApplicationServices
import Foundation

/// A read-only, bounded marker adapter for explicit reading lookups. The selection reader owns
/// its opaque marker receipt; only text and exact local offsets leave this synchronous boundary.
/// No document-start/end queries or clipboard actions are used to obtain surrounding context.
@MainActor
enum AXReadingContext {
    /// One transient native range plus its acquisition evidence; it never leaves this adapter.
    private struct Candidate {
        let range: CFTypeRef
        let method: LearningReadingWindow.Method
        let boundary: LearningReadingWindow.Boundary
    }

    static func selection(on element: AXUIElement) -> CFTypeRef? {
        value("AXSelectedTextMarkerRange", on: element)
    }

    /// Browser selections often belong to the web area. A marker may still locate their leaf
    /// even when paragraph/string-range queries fail; never substitute the current mouse hit.
    static func selectedElement(on element: AXUIElement) -> AXUIElement? {
        guard let receipt = selection(on: element),
              let ordered = AXHelper.orderedReadingTextMarkerRange(receipt, on: element),
              let endpoints = AXHelper.textMarkerEndpoints(from: ordered),
              let result = parameter("AXUIElementForTextMarker", endpoints.start, on: element),
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(result, to: AXUIElement.self)
    }

    static func matches(_ saved: CFTypeRef, on element: AXUIElement) -> Bool {
        guard let current = selection(on: element),
              let left = AXHelper.textMarkerEndpoints(from: saved),
              let right = AXHelper.textMarkerEndpoints(from: current) else { return false }
        return CFEqual(left.start, right.start) && CFEqual(left.end, right.end)
    }

    /// Structural block ranges are preferred over host sentence labels. The latter can stop
    /// at a link/span, so they remain unproven candidates until the shared policy finds boundaries.
    static func read(on element: AXUIElement, expected: String, deadline: ContinuousClock.Instant,
                     explicitRange: NSRange? = nil) -> [LearningReadingWindow] {
        let receipt = explicitRange.flatMap { characterMarkers($0, on: element) } ??
            (explicitRange == nil ? selection(on: element) : nil)
        guard ContinuousClock.now < deadline, let receipt,
              let ordered = AXHelper.orderedReadingTextMarkerRange(receipt, on: element),
              let selected = AXHelper.textMarkerEndpoints(from: ordered),
              expected.utf16.count <= LearningReadingContextPolicy.maximumSelectionUTF16 else {
            LearningReadingLog.emit(.axMarkers, ContinuousClock.now >= deadline ? "deadline-exhausted" : "markers-unavailable")
            return []
        }
        // Keep `receipt` directed for the final identity check. Every text partition and marker
        // walk below uses the ordered copy so a backward drag addresses the same occurrence.
        if let original = AXHelper.textMarkerEndpoints(from: receipt),
           CFEqual(original.start, selected.end), !CFEqual(original.start, selected.start) {
            LearningReadingLog.emit(.axMarkers, "selection-reordered")
        }
        var windows: [LearningReadingWindow] = []
        func append(_ candidate: CFTypeRef?, method: LearningReadingWindow.Method,
                    boundary: LearningReadingWindow.Boundary = .unknown) -> Bool {
            guard let candidate, let window = candidateWindow(.init(range: candidate, method: method, boundary: boundary),
                selection: ordered, expected: expected, on: element, deadline: deadline) else { return false }
            windows.append(window)
            return LearningReadingContextPolicy.resolve(window, expected: expected)?.isComplete == true
        }
        // Prefer the enclosing group over a flattened root string. Offscreen Chromium groups
        // lose useful geometry; their text still helps, but their edges remain explicitly unknown.
        let blocks = blockRanges(selected.start, on: element, deadline: deadline)
        let orderedBlocks = Array(blocks.reversed())
        for block in orderedBlocks {
            let count = windows.count
            _ = append(block.range, method: .block, boundary: block.boundary)
            if windows.count > count, LearningReadingContextPolicy.resolve(windows[count], expected: expected) != nil {
                return verified(windows, receipt: receipt, on: element, selectionOnly: explicitRange == nil)
            }
        }
        // Large paragraphs are walked locally and never escape their enclosing range. Reading
        // a web-area string would concatenate headings, links and paragraphs without separators.
        for block in blocks {
            if let window = boundedWindow(block, selection: ordered, expected: expected, on: element, deadline: deadline) {
                windows.append(window)
                if LearningReadingContextPolicy.resolve(window, expected: expected) != nil {
                    return verified(windows, receipt: receipt, on: element, selectionOnly: explicitRange == nil)
                }
            }
        }
        let queries: [((String, String?), LearningReadingWindow.Method)] = [
            (("AXPreviousParagraphStartTextMarkerForTextMarker", "AXNextParagraphEndTextMarkerForTextMarker"), .paragraph),
            (("AXPreviousSentenceStartTextMarkerForTextMarker", "AXNextSentenceEndTextMarkerForTextMarker"), .sentence),
            (("AXParagraphTextMarkerRangeForTextMarker", nil), .paragraph),
            (("AXSentenceTextMarkerRangeForTextMarker", nil), .sentence)
        ]
        for query in queries {
            guard ContinuousClock.now < deadline else { break }
            if append(candidate(query.0, selected: selected, on: element), method: query.1) { break }
        }
        return verified(windows, receipt: receipt, on: element, selectionOnly: explicitRange == nil)
    }

    private static func verified(_ windows: [LearningReadingWindow], receipt: CFTypeRef,
                                 on element: AXUIElement, selectionOnly: Bool) -> [LearningReadingWindow] {
        if selectionOnly && !matches(receipt, on: element) {
            LearningReadingLog.emit(.axMarkers, "selection-changed"); return []
        }
        LearningReadingLog.emit(.axMarkers, windows.isEmpty ? "no-marker-candidates" : "candidates",
            details: ["candidate_count": String(windows.count)])
        return windows
    }

    private static func characterMarkers(_ range: NSRange, on element: AXUIElement) -> CFTypeRef? {
        guard range.location >= 0, range.length > 0,
              range.location <= Int.max - range.length,
              let start = parameter("AXTextMarkerForIndex", NSNumber(value: range.location), on: element),
              let end = parameter("AXTextMarkerForIndex", NSNumber(value: NSMaxRange(range)), on: element) else { return nil }
        return parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray, on: element)
    }

    private static func blockRanges(_ start: AXTextMarker, on element: AXUIElement,
                                    deadline: ContinuousClock.Instant) -> [Candidate] {
        guard let value = parameter("AXUIElementForTextMarker", start, on: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        // Type checking is required before borrowing the CF reference as an AX element.
        var node: AXUIElement? = unsafeBitCast(value, to: AXUIElement.self)
        var result: [Candidate] = []
        let roles: Set<String> = ["AXParagraph", "AXHeading", "AXListItem", "AXCell", "AXTextArea", "AXTextField"]
        for _ in 0..<7 {
            guard ContinuousClock.now < deadline, let current = node else { break }
            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: current) ?? ""
            if role == "AXWebArea" { break }
            let parent = AXHelper.elementValue(for: kAXParentAttribute as CFString, on: current)
            let semantic = roles.contains(role)
            let layout = role == "AXGroup" && parent.map { separatedGroup(current, parent: $0, deadline: deadline) } == true
            if semantic || role == "AXGroup", let range = parameter("AXTextMarkerRangeForUIElement", current, on: element) {
                result.append(.init(range: range, method: .block,
                    boundary: semantic ? .container : layout ? .layoutBlock : .unknown))
                if semantic { break }
            }
            node = parent
        }
        return result
    }

    private static func separatedGroup(_ element: AXUIElement, parent: AXUIElement,
                                       deadline: ContinuousClock.Instant) -> Bool {
        guard ContinuousClock.now < deadline,
              let index = parameter("AXIndexForChildUIElement", element, on: parent) as? NSNumber,
              let frame = frame(element) else { return false }
        var count = 0
        guard AXUIElementGetAttributeValueCount(parent, kAXChildrenAttribute as CFString, &count) == .success,
              index.intValue >= 0, index.intValue < count else { return false }
        let first = index.intValue == 0, last = index.intValue == count - 1
        // A sole child can simply be another inline wrapper. Only a document root proves both
        // outer boundaries in that case; otherwise continue the bounded ancestor walk.
        if first && last && AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: parent) != "AXWebArea" { return false }
        func sibling(_ offset: Int) -> CGRect? {
            guard ContinuousClock.now < deadline else { return nil }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(parent, kAXChildrenAttribute as CFString,
                index.intValue + offset, 1, &values) == .success,
                let node = (values as? [AXUIElement])?.first else { return nil }
            return self.frame(node)
        }
        return LearningReadingBlockPolicy.separates(frame, before: first ? nil : sibling(-1),
            after: last ? nil : sibling(1), first: first, last: last)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(kAXPositionAttribute as String, on: element),
              let size = value(kAXSizeAttribute as String, on: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        // Type-checked AXValue reads use screen coordinates throughout; no display flip is needed.
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func boundedWindow(_ block: Candidate, selection: CFTypeRef, expected: String,
                                      on element: AXUIElement, deadline: ContinuousClock.Instant) -> LearningReadingWindow? {
        guard ContinuousClock.now < deadline, let bounds = AXHelper.textMarkerEndpoints(from: block.range),
              let selected = AXHelper.textMarkerEndpoints(from: selection),
              let prefix = markerRange(bounds.start, selected.start, on: element),
              let suffix = markerRange(selected.end, bounds.end, on: element),
              let selectedLength = length(selection, on: element), selectedLength > 0,
              selectedLength <= LearningReadingContextPolicy.maximumSelectionUTF16,
              let total = length(block.range, on: element), total >= selectedLength,
              let beforeCount = length(prefix, on: element), beforeCount <= total - selectedLength,
              let afterCount = length(suffix, on: element),
              afterCount == total - selectedLength - beforeCount else { return nil }
        // Marker equality is not guaranteed at equivalent node-edge positions. Cap movement
        // by measured distance to the ancestor edge as well as by the global context budget.
        let walkDeadline = deadline.advanced(by: .milliseconds(-20))
        let after = walk(.init(start: selected.end, stop: bounds.end, limit: min(512, afterCount)), forward: true,
            on: element, deadline: walkDeadline)
        guard let afterRange = markerRange(selected.end, after, on: element),
              let afterLength = length(afterRange, on: element), afterLength <= 1_024 else { return nil }
        let before = walk(.init(start: selected.start, stop: bounds.start, limit: min(1_024 - afterLength, beforeCount)), forward: false,
            on: element, deadline: walkDeadline)
        guard let range = markerRange(before, after, on: element),
              let window = candidateWindow(.init(range: range, method: .markerWalk, boundary: .crop),
                selection: selection, expected: expected, on: element, deadline: deadline) else { return nil }
        return .init(text: window.text, target: window.target,
            left: CFEqual(before, bounds.start) ? block.boundary : .crop,
            right: CFEqual(after, bounds.end) ? block.boundary : .crop, method: .markerWalk,
            targetIntroducesLineBreaks: window.targetIntroducesLineBreaks)
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

    private static func candidateWindow(_ candidate: Candidate, selection: CFTypeRef, expected: String,
                                        on element: AXUIElement, deadline: ContinuousClock.Instant) -> LearningReadingWindow? {
        guard ContinuousClock.now < deadline, let bounds = AXHelper.textMarkerEndpoints(from: candidate.range),
              let selected = AXHelper.textMarkerEndpoints(from: selection),
              let beforeRange = markerRange(bounds.start, selected.start, on: element),
              let afterRange = markerRange(selected.end, bounds.end, on: element),
              let beforeLength = length(beforeRange, on: element), let afterLength = length(afterRange, on: element),
              beforeLength <= 1_024, afterLength <= 1_024, beforeLength + afterLength <= 1_024,
              let total = length(candidate.range, on: element),
              let selectedLength = length(selection, on: element), selectedLength > 0,
              selectedLength <= LearningReadingContextPolicy.maximumSelectionUTF16,
              total == beforeLength + selectedLength + afterLength,
              total <= LearningReadingContextPolicy.maximumSelectionUTF16 + 1_024,
              ContinuousClock.now < deadline else {
            LearningReadingLog.emit(.axMarkers, ContinuousClock.now >= deadline ? "deadline-exhausted" : "range-unverified",
                details: ["method": candidate.method.rawValue])
            return nil
        }
        guard let before = string(beforeRange, maximum: 1_024, on: element),
              ContinuousClock.now < deadline,
              let target = string(selection, maximum: LearningReadingContextPolicy.maximumSelectionUTF16, on: element),
              ContinuousClock.now < deadline, let after = string(afterRange, maximum: 1_024, on: element),
              ContinuousClock.now < deadline,
              let whole = string(candidate.range, maximum: total, on: element),
              whole.utf16.elementsEqual((before + target + after).utf16) else {
            LearningReadingLog.emit(.axMarkers, ContinuousClock.now >= deadline ? "deadline-exhausted" : "text-partition-mismatch",
                details: ["method": candidate.method.rawValue])
            return nil
        }
        let window = LearningReadingWindow(text: whole, target: NSRange(location: before.utf16.count, length: target.utf16.count),
            left: candidate.boundary, right: candidate.boundary, method: candidate.method)
        let aligned = LearningReadingTargetPolicy.aligned(window, expected: expected)
        LearningReadingLog.emit(.axMarkers, aligned == nil ? "target-mismatch" : "matched", details: ["method": candidate.method.rawValue])
        return aligned
    }

    /// Each walk is restricted to an ancestor range, a call count, a character budget and a
    /// deadline. Keep the last measured marker if a host returns an unexpectedly wide step.
    private struct Walk {
        let start: AXTextMarker
        let stop: AXTextMarker
        let limit: Int
    }
    private static func walk(_ span: Walk, forward: Bool, on element: AXUIElement,
                             deadline: ContinuousClock.Instant) -> AXTextMarker {
        var current = span.start
        for _ in 0..<span.limit {
            guard ContinuousClock.now < deadline, !CFEqual(current, span.stop) else { break }
            let name = forward ? "AXNextTextMarkerForTextMarker" : "AXPreviousTextMarkerForTextMarker"
            guard let nextValue = parameter(name, current, on: element), CFGetTypeID(nextValue) == AXTextMarkerGetTypeID() else { break }
            let next = unsafeBitCast(nextValue, to: AXTextMarker.self)
            guard !CFEqual(next, current), let range = markerRange(span.start, next, on: element),
                  let count = length(range, on: element), count <= span.limit else { break }
            current = next
        }
        return current
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
