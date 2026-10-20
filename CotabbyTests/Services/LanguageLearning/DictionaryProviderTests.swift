import Foundation
import Testing
@testable import Cotabby

struct DictionaryProviderTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func importsMDXMDDAndFollowsOnlyBoundedReferences() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Book.mdx")
        try DictionaryFixture.v2.write(to: url)
        try DictionaryFixture.mdd.write(to: root.appendingPathComponent("Book.mdd"))
        try Data(".word{color:blue}".utf8).write(to: root.appendingPathComponent("Book.css"))
        let service = MDictLibraryService()
        let library = try await service.importFile(url)
        #expect(library.resources.count == 1 && library.entryCount == 3)
        guard case .article(let article) = try await service.lookup("alias", library: library) else {
            Issue.record("Alias should resolve to a rich definition"); return
        }
        #expect(article.html.contains("Hello") && article.html.contains("Book.css"))
        #expect(article.text.contains("Hello world") && article.resourceLibrary == library.id)
        #expect(try await service.lookup("cycle", library: library) == .notFound)
        let image = try #require(try await service.resource("test.png", library: library))
        #expect(image.mimeType == "image/png" && image.data.count < 100)
        #expect(try await service.resource("../secret.css", library: library) == nil)
        let external = try folder()
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("secret".utf8).write(to: external.appendingPathComponent("escape.css"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.css"),
                                                  withDestinationURL: external.appendingPathComponent("escape.css"))
        #expect(try await service.resource("escape.css", library: library) == nil)
        var oversized = library
        oversized.resources = Array(repeating: library.mdx, count: 17)
        await #expect(throws: (any Error).self) { _ = try await service.lookup("hello", library: oversized) }
        // A cached mapping must not bypass validation after the original file is truncated.
        try Data().write(to: url)
        await #expect(throws: (any Error).self) { _ = try await service.lookup("hello", library: library) }
    }

    @Test func decodingOnlineDefinitionsPreservesAttributionAndIgnoresRemoteAudio() throws {
        let json = """
        [{"word":"hello","phonetics":[{"text":"/həˈləʊ/","audio":"https://elsewhere.invalid/audio.mp3"}],
        "meanings":[{"partOfSpeech":"interjection","definitions":[{"definition":"A greeting.","example":"Hello, friend."}]}],
        "sourceUrls":["file:///etc/passwd","https://en.wiktionary.org/wiki/hello"],
        "license":{"name":"CC BY-SA 3.0","url":"https://creativecommons.org/licenses/by-sa/3.0/"}}]
        """
        guard case .entries(let entries) = try OnlineDictionaryClient.decode(Data(json.utf8)) else {
            Issue.record("Expected structured API definitions"); return
        }
        let entry = try #require(entries.first)
        #expect(entry.phonetics == ["/həˈləʊ/"] && entry.examples == ["Hello, friend."])
        #expect(entry.sourceURL == "https://en.wiktionary.org/wiki/hello" && entry.licenseName == "CC BY-SA 3.0")
        #expect(OnlineDictionaryClient.url(for: "a/b?x=1")?.host == "api.dictionaryapi.dev")
        #expect(OnlineDictionaryClient.url(for: "a/b?x=1")?.query == nil)
    }

    @Test func disabledRemoteSourcesDoNotPerformRequests() async throws {
        let router = LearningDictionaryRouter(lexicon: LearningLexiconService(resourceURL: nil))
        #expect(try await router.lookup("hello", language: .english, expression: false, source: .online,
                                       configuration: .init()) == .notFound)
        var configuration = LearningDictionaryConfiguration(enabled: [.online])
        #expect(try await router.lookup("bonjour", language: .french, expression: false, source: .online,
                                       configuration: configuration) == .notFound)
        let site = DictionaryWebsite(id: UUID(), name: "Example", template: "https://example.org/find?q={query}")
        configuration = .init(enabled: [site.source], websites: [site])
        guard case .website(let url) = try await router.lookup("hello", language: .english, expression: false,
                                                               source: site.source, configuration: configuration) else {
            Issue.record("Website source must return a URL instead of fetching it"); return
        }
        #expect(url.host == "example.org" && url.query == "q=hello")
    }

    @Test func unavailablePrivateHelperIsRecoverable() async throws {
        let service = SystemDictionaryArticleService(executable: URL(fileURLWithPath: "/does-not-exist"))
        #expect(try await service.lookup("hello") == nil)
    }
}

@MainActor
struct DictionaryExpandedSettingsTests {
    @Test func explicitOnlineOptInAndWebsiteEditingSurviveReload() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningDictionarySettings(defaults: defaults)
        #expect(!settings.configuration.enabled.contains(.online))
        let website = DictionaryWebsite(id: UUID(), name: "Example", template: "https://example.org/{query}")
        settings.save(website)
        #expect(!settings.configuration.enabled.contains(website.source))
        settings.setEnabled(true, for: website.source)
        var edited = website
        edited.name = "New name"
        settings.save(edited)
        settings.setSystemFormat(.text)
        let reopened = LearningDictionarySettings(defaults: defaults)
        #expect(reopened.configuration == settings.configuration)
        #expect(reopened.configuration.websites.count == 1)
        #expect(reopened.configuration.enabled.contains(website.source))
        reopened.remove(website.source)
        #expect(!reopened.configuration.order.contains(website.source))
    }

    @Test func savedQuotesKeepSourceSpecificLicense() {
        let entry = LearningLexiconEntry(id: "test", language: "en", headword: "hello", forms: [],
            senses: [.init(partOfSpeech: "noun", definitions: ["A greeting."], labels: [])],
            sourceURL: "https://example.org/hello", sourceName: "Example", licenseURL: "https://example.org/license",
            licenseName: "Example license")
        let values = VocabularyCaptureFactory.definitions(.result(.entries([entry])))
        #expect(values.first?.source == "Example" && values.first?.licenseName == "Example license")
        #expect(values.first?.licenseURL == "https://example.org/license")
    }
}
