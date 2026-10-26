import ApplicationServices
import Foundation
import Logging

/// Acquires competing bounded windows, then lets the shared pure policy choose evidence.
/// One deadline covers all paths. A partial ordinary range cannot suppress a better marker range.
@MainActor
enum LearningVocabularyContextReader {
    static func read(element: AXUIElement, range: NSRange?, expected: String,
                     selection: Bool = true) -> LearningReadingContext? {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(180))
        var windows: [LearningReadingWindow] = []
        if let window = ordinary(element: element, range: range, expected: expected) { windows.append(window) }
        if LearningReadingContextPolicy.best(windows, expected: expected)?.isComplete != true {
            windows += AXReadingContext.read(on: element, expected: expected, deadline: deadline,
                explicitRange: selection ? nil : range)
        }
        var result = LearningReadingContextPolicy.best(windows, expected: expected)
        let needsBlockProof = result == nil || (result?.completeness == .unknown &&
            result?.selectionCoversContext == true && result?.hasBlockCoverage == false)
        if selection, needsBlockProof,
           let block = AXReadingSelectedBlock.read(on: element, expected: expected, deadline: deadline) {
            windows.append(block)
            result = LearningReadingContextPolicy.resolve(block, expected: expected) ?? result
        }
        log(result, candidates: windows.count, exhausted: ContinuousClock.now >= deadline)
        return result
    }

    private static func ordinary(element: AXUIElement, range: NSRange?, expected: String) -> LearningReadingWindow? {
        guard let range else { LearningReadingLog.emit(.axRange, "range-unavailable"); return nil }
        guard let count = AXHelper.intValue(for: kAXNumberOfCharactersAttribute as CFString, on: element) else {
            LearningReadingLog.emit(.axRange, "character-count-unavailable"); return nil
        }
        guard let window = LearningReadingContextPolicy.windowRange(target: range, count: count) else {
            LearningReadingLog.emit(.axRange, "range-out-of-bounds"); return nil
        }
        guard let text = AXHelper.parameterizedStringValue(for: kAXStringForRangeParameterizedAttribute as CFString,
            range: window, on: element) else { LearningReadingLog.emit(.axRange, "text-unavailable"); return nil }
        guard text.utf16.count == window.length else { LearningReadingLog.emit(.axRange, "window-length-mismatch"); return nil }
        // Static-text ends only prove a node edge. Actual editable containers/paragraphs carry
        // structural evidence; a browser's inline span must remain unproven even at index zero.
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        let structural = ["AXTextArea", "AXTextField", "AXParagraph", "AXHeading", "AXListItem", "AXCell"].contains(role)
        let candidate = LearningReadingWindow(text: text,
            target: NSRange(location: range.location - window.location, length: range.length),
            left: window.location == 0 ? (structural ? .container : .unknown) : .crop,
            right: NSMaxRange(window) == count ? (structural ? .container : .unknown) : .crop, method: .characters)
        let aligned = LearningReadingTargetPolicy.aligned(candidate, expected: expected)
        LearningReadingLog.emit(.axRange, aligned == nil ? "target-mismatch" : "matched")
        return aligned
    }

    static func log(_ context: LearningReadingContext?, candidates: Int = 1, exhausted: Bool = false) {
        LingroveLogger.learning.debug("Reading context captured", metadata: [
            "request_id": .string(LearningRequestTrace.requestID ?? "unscoped"),
            "method": .string(context?.window.method.rawValue ?? "unavailable"),
            "scope": .string(context.map { $0.isComplete ? "complete" : $0.completeness.rawValue } ?? "none"),
            "left_boundary": .string(context?.left.rawValue ?? "unknown"),
            "right_boundary": .string(context?.right.rawValue ?? "unknown"),
            "context_utf16": .stringConvertible(context?.text.utf16.count ?? 0),
            "window_utf16": .stringConvertible(context?.window.text.utf16.count ?? 0),
            "candidate_count": .stringConvertible(candidates), "deadline_exhausted": .stringConvertible(exhausted),
            "target_offset": .stringConvertible(context?.target.location ?? -1),
            "sentence_count": .stringConvertible(context?.sentenceCount ?? 0),
            "ocr_confidence": .string(context?.window.confidence.map(String.init(describing:)) ?? "unavailable")
        ])
    }
}
