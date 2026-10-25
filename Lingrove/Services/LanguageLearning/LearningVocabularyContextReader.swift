import ApplicationServices
import Foundation

/// A bounded optional read attached to an explicit selection receipt. Failure never blocks
/// translation. Explicit contextual lookup may pass this bounded text to the configured general model.
@MainActor
enum LearningVocabularyContextReader {
    static func read(element: AXUIElement, range: NSRange?, expected: String, app: String) -> VocabularyExample? {
        guard let range, range.location >= 0, range.length > 0, range.length <= 3_072,
              let count = AXHelper.intValue(for: kAXNumberOfCharactersAttribute as CFString, on: element),
              range.location <= count, range.length <= count - range.location else { return nil }
        let start = max(0, range.location - 512)
        let end = min(count, NSMaxRange(range) + 512)
        let window = NSRange(location: start, length: end - start)
        guard let text = AXHelper.parameterizedStringValue(for: kAXStringForRangeParameterizedAttribute as CFString,
            range: window, on: element) else { return nil }
        let local = NSRange(location: range.location - start, length: range.length)
        guard VocabularyPolicy.valid(local, in: text), (text as NSString).substring(with: local) == expected else { return nil }
        return VocabularyPolicy.example(text: text, ranges: [local], language: LearningLanguage.detect(in: text) ?? .english,
            startsAtBoundary: start == 0, endsAtBoundary: end == count, app: app)
    }
}
