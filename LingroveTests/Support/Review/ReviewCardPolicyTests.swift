import LingroveNotebook
import Foundation
import Testing
@testable import Lingrove

struct ReviewCardPolicyTests {
    @Test(arguments: ["https://127.0.0.1:8765", "http://example.com", "http://127.0.0.1@evil.com", "http://localhost/a",
                      "http://localhost?secret=x", "http://localhost#x", "http://localhost:0"])
    func connectionNeverBroadensToAnotherHost(_ text: String) { #expect(AnkiReviewPolicy.endpoint(text) == nil) }

}
