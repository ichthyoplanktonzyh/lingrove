import Foundation
import Testing
@testable import Cotabby

/// Keeps endpoint output safe before translation display or hint decoding. The checks are pure, so
/// malformed, oversized, or control-heavy responses can be covered without an HTTP endpoint.
@Suite
struct LearningExpressionOutputPolicyTests {
    @Test
    func streamedPrefixesSkipWhitespaceAndPreserveWordBoundaries() throws {
        var stream = LearningExpressionOutputPolicy.Stream()
        #expect(try stream.append(" \n") == nil)
        #expect(try stream.append("Hello ") == "Hello")
        #expect(try stream.append("世界") == "Hello 世界")
        #expect(try stream.append(".\nSecond line.") == "Hello 世界.\nSecond line.")
    }

    @Test
    func streamRejectsCorruptionAndBoundsAccumulatedUtf8BeforeDisplay() throws {
        var unsafe = LearningExpressionOutputPolicy.Stream()
        #expect(try unsafe.append("Hello") == "Hello")
        #expect(throws: LearningFailure.self) { try unsafe.append("\u{0000}world") }
        var bounded = LearningExpressionOutputPolicy.Stream()
        _ = try bounded.append(String(repeating: "界", count: 4_000))
        #expect(throws: LearningFailure.self) { try bounded.append("a") }
    }

    @Test
    func trimsOnlyResponseEdgesAndPreservesInternalLineFeeds() throws {
        #expect(try LearningExpressionOutputPolicy.validatedText(" \nI did not send 2 files today.\n ")
            == "I did not send 2 files today.")
        #expect(try LearningExpressionOutputPolicy.validatedText("\nFirst line.\n\nSecond line.\n")
            == "First line.\n\nSecond line.")
    }

    @Test
    func rejectsEmptyOrWhitespaceOnlyOutput() {
        #expect(throws: LearningFailure.self) {
            try LearningExpressionOutputPolicy.validatedText(" \n\t ")
        }
    }

    @Test(arguments: ["\u{0000}", "\u{0001}", "\u{0009}", "\u{001B}", "\u{007F}", "\u{FFFD}"])
    func rejectsUnsafeCharactersBeforePresentation(_ invalid: String) {
        #expect(throws: LearningFailure.self) {
            try LearningExpressionOutputPolicy.validatedText("I did\(invalid) not send it.")
        }
    }

    @Test
    func enforcesTheWholeResponseUtf8Budget() throws {
        let atLimit = String(repeating: "a", count: 12_000)
        let overLimit = String(repeating: "a", count: 12_001)

        #expect(try LearningExpressionOutputPolicy.validatedText(atLimit) == atLimit)
        #expect(throws: LearningFailure.self) {
            try LearningExpressionOutputPolicy.validatedText(overLimit)
        }
    }
}
