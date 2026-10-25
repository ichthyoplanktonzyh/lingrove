import ApplicationServices
import Foundation
import Logging

/// A bounded optional read attached to an explicit selection receipt. Failure never blocks
/// translation. Explicit contextual lookup may pass this bounded text to the configured general model.
@MainActor
enum LearningVocabularyContextReader {
    static func read(element: AXUIElement, range: NSRange?, expected: String, app: String) -> VocabularyExample? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
        if let example = ordinary(element: element, range: range, expected: expected, app: app) {
            log("character-range", example: example)
            return example
        }
        if let window = AXReadingContext.read(on: element, expected: expected, deadline: deadline),
           let example = LearningReadingContextPolicy.example(text: window.text, range: window.range, expected: expected,
               startsAtBoundary: window.complete, endsAtBoundary: window.complete, app: app) {
            log(window.method, example: example)
            return example
        }
        log("unavailable", example: nil)
        return nil
    }

    private static func ordinary(element: AXUIElement, range: NSRange?, expected: String, app: String) -> VocabularyExample? {
        guard let range, range.location >= 0, range.length > 0, range.length <= 3_072,
              let count = AXHelper.intValue(for: kAXNumberOfCharactersAttribute as CFString, on: element),
              range.location <= count, range.length <= count - range.location else { return nil }
        let start = max(0, range.location - 512)
        let end = NSMaxRange(range) + min(512, count - NSMaxRange(range))
        let window = NSRange(location: start, length: end - start)
        guard let text = AXHelper.parameterizedStringValue(for: kAXStringForRangeParameterizedAttribute as CFString,
            range: window, on: element) else { return nil }
        let local = NSRange(location: range.location - start, length: range.length)
        guard VocabularyPolicy.valid(local, in: text) else { return nil }
        return LearningReadingContextPolicy.example(text: text, range: local, expected: expected,
            startsAtBoundary: start == 0, endsAtBoundary: end == count, app: app)
    }
    private static func log(_ method: String, example: VocabularyExample?) {
        LingroveLogger.learning.debug("Reading context captured", metadata: [
            "method": .string(method), "scope": .string(example?.completeness.rawValue ?? "none"),
            "context_utf16": .stringConvertible(example?.text.utf16.count ?? 0)
        ])
    }
}
