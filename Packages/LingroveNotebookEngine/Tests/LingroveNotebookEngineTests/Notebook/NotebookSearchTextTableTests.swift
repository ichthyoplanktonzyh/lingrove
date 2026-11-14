import Foundation
import Testing
@testable import LingroveNotebookEngine

struct NotebookSearchTextTableTests {
    @Test func asciiSubstringMatchesLiteralFoundationIncludingRepeatedPrefixesAndNULs() {
        var seed: UInt64 = 5381
        func bytes(_ count: Int) -> [UInt8] {
            (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return UInt8((seed >> 32) % 128)
            }
        }
        var cases = [("ababaababac", "ababac"), ("ababaababac", "abababc"), ("prefix\0SUFFIX", "\0suffix"),
                     (String(repeating: "a", count: 4096) + "b", String(repeating: "a", count: 512) + "b"),
                     (String(repeating: "a", count: 4096), String(repeating: "a", count: 512) + "b")]
        for number in 0..<500 {
            let source = bytes(40), needle = number.isMultiple(of: 2) ? Array(source[13..<19]) : bytes(6)
            cases.append((String(decoding: source, as: UTF8.self), String(decoding: needle, as: UTF8.self)))
        }
        for (source, needle) in cases {
            var builder = NotebookSearchTextTable.Builder()
            let id = builder.intern(source)
            var matcher = NotebookSearchTextTable.Matcher(table: builder.finish(), term: needle, locale: "en_US")
            let expected = source.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            #expect(matcher.contains(id) == expected)
            #expect(matcher.contains(id) == expected)
        }
    }
}
