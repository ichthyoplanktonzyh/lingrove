import Foundation
import Testing
@testable import LingroveNotebookEngine

struct TimestampFormattingTests {
    @Test func sharedFormatterPreservesFoundationBytesAcrossConcurrentCalls() async {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let offsets: [Double] = [-2_208_988_800, -1.0009, -0.0009, 0, 0.0004, 0.0009, 0.9999]
            + (0..<256).map { 1_700_000_000 + Double($0) * 86_399.123456 }
        let expected = offsets.map { value -> (Date, String) in
            let date = Date(timeIntervalSince1970: value)
            return (date, reference.string(from: date))
        }
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { expected.allSatisfy { formatIsoTimestamp(date: $0.0) == $0.1 } }
            }
            for await matches in group { #expect(matches) }
        }
    }
}
