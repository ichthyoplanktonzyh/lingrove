import Foundation
import Testing
@testable import Cotabby

struct DictionaryContentPolicyTests {
    @Test(arguments: ["../secret", "%2e%2e/secret", "\\..\\secret", "file:///etc/passwd", "a/../../b", "a\0b"])
    func unsafeResourcePathsAreRejected(_ path: String) {
        #expect(DictionaryContentPolicy.resourcePath(path) == nil)
    }
    @Test func localResourceKeysAreNormalized() {
        #expect(DictionaryContentPolicy.resourcePath("\\images\\a.png") == "images/a.png")
        #expect(DictionaryContentPolicy.resourcePath("/a%20b.css") == "a b.css")
    }
    @Test(arguments: ["http://example.org/{query}", "https://{query}.example.org/", "https://user:pass@example.org/{query}",
                     "https://example.org/", "https://example.org/{query}/{query}", "file:///{query}"])
    func unsafeWebsiteTemplatesAreRejected(_ template: String) {
        #expect(DictionaryWebsitePolicy.url(template: template, query: "hello") == nil)
    }
    @Test func queryCannotChangeWebsiteHostPathOrArguments() throws {
        let url = try #require(DictionaryWebsitePolicy.url(template: "https://example.org/search?q={query}", query: "a/b & c#d?e"))
        #expect(url.host == "example.org" && url.path == "/search" && url.fragment == nil)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 1)
        #expect(DictionaryLinkPolicy.externalURL("javascript:alert(1)") == nil)
        #expect(DictionaryLinkPolicy.externalURL("file:///etc/passwd") == nil)
        #expect(DictionaryLinkPolicy.reference(try #require(URL(string: "entry://hello%20world"))) == "hello world")
    }
    @Test func richDocumentsHaveANetworkAndExecutionBoundary() {
        let html = DictionaryHTMLPolicy.document("<html><head><base href='file:///tmp/'><meta http-equiv='refresh' content='0;url=https://evil.invalid'></head><body><p>word</p></body></html>")
        #expect(!html.contains("<base ") && !html.contains("http-equiv='refresh'"))
        #expect(html.contains("script-src 'none'") && html.contains("connect-src 'none'") && html.contains("base-uri 'none'"))
        #expect(html.contains("<p>word</p>"))
    }
}
