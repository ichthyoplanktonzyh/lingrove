import Foundation
import Testing
@testable import Lingrove

@MainActor
struct DictionaryLanguagePairTests {
    @Test func languageAnnotationReportsPersistenceFailureWithoutChangingTheSavedBook() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningDictionarySettings(defaults: defaults), id = UUID()
        func book(_ bytes: Int) -> MDictLibraryDescriptor {
            let file = DictionaryFileReference(path: "/fixture.mdx", bookmark: Data(repeating: 1, count: bytes))
            return .init(id: id, name: "Book", mdx: file, resources: [], folder: file, entryCount: 1)
        }
        #expect(settings.add(book(0)))
        let overhead = try #require(defaults.data(forKey: "learningDictionaryCatalog")).count
        let bytes = (2_000_000 - overhead - 24) / 8 * 3
        #expect(settings.add(book(bytes)))
        #expect(try #require(defaults.data(forKey: "learningDictionaryCatalog")).count > 1_999_900)
        #expect(!settings.setLanguages(.init(entry: .english, definition: .chinese, multilingual: false), for: .mdict(id)))
        #expect(settings.configuration.libraries.first?.languages == nil)
        #expect(LearningDictionarySettings(defaults: defaults).configuration == settings.configuration)
    }

    @Test(arguments: ["zh-Hant-HK", "zh-HK", "zh_TW", "zh-MO"])
    func traditionalSystemLocalesRetainTheirScript(_ locale: String) {
        #expect(DictionaryLanguagePair.definitionLanguage(for: locale) == .traditionalChinese)
        #expect(DictionaryLanguagePair.definitionLanguage(for: "zh-SG") == .chinese)
        #expect(DictionaryLanguagePair.definitionLanguage(for: "de-DE") == .german)
    }

    @Test func oldCatalogAndCustomSourcesSurviveLanguageMetadataMigration() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let old: [String: Any] = ["libraries": [], "websites": [["id": id.uuidString, "name": "Old book",
            "template": "https://example.org/{query}"]], "systemFormat": "text"]
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "learningDictionaryCatalog")
        let settings = LearningDictionarySettings(defaults: defaults)
        #expect(settings.configuration.websites.first?.id == id)
        #expect(settings.configuration.websites.first?.languages == nil)
        #expect(settings.configuration.systemFormat == .text)
        settings.setDefinitionLanguage(.chinese)
        settings.add(DictionaryWebsiteCatalog.websites[0])
        settings.add(DictionaryWebsiteCatalog.websites[0])
        #expect(settings.configuration.websites.count == 2)
        #expect(!settings.configuration.enabled.contains(DictionaryWebsiteCatalog.websites[0].source))
        #expect(LearningDictionarySettings(defaults: defaults).configuration == settings.configuration)
        settings.setDefinitionLanguage(nil)
        #expect(LearningDictionarySettings(defaults: defaults).configuration.definitionLanguage == nil)
    }

    @Test func routingKeepsEntryLanguageAndFallsBackOnlyForTheGlossLanguage() {
        let french = DictionaryWebsite(id: UUID(), name: "French", template: "https://example.org/{query}",
                                       languages: .init(entry: .french, definition: .chinese))
        let english = DictionaryWebsiteCatalog.websites[0]
        let configuration = LearningDictionaryConfiguration(enabled: [.bundled, .system, .online, french.source, english.source],
            websites: [french, english], definitionLanguage: .chinese)
        #expect(!configuration.sources(for: .english).contains(french.source))
        #expect(!configuration.sources(for: .french).contains(.online))
        #expect(configuration.automaticSources(for: .english) == [.system, .bundled, .online])
        #expect(configuration.sources(for: .english).contains(english.source))
        #expect(DictionaryLanguagePair(entry: .chinese, definition: .english).supports(.traditionalChinese))
        #expect(!DictionaryLanguagePair(entry: .japanese, definition: .english).supports(.chinese))
    }

    @Test func curatedTemplatesPreserveHostAndEncodeOnlyTheTerm() throws {
        #expect(Set(DictionaryWebsiteCatalog.websites.map(\.id)).count == DictionaryWebsiteCatalog.websites.count)
        for site in DictionaryWebsiteCatalog.websites {
            let url = try #require(DictionaryWebsitePolicy.url(template: site.template, query: "你好 / hello?x=1#"))
            #expect(url.scheme == "https" && url.query == nil && url.fragment == nil)
            #expect(url.host == URL(string: site.template.replacingOccurrences(of: "{query}", with: "word"))?.host)
        }
    }

    @Test func unannotatedBooksRequireExplicitSelectionUntilTheirEntryLanguageIsKnown() {
        let reference = DictionaryFileReference(path: "/fixture/book.mdx", bookmark: Data())
        var book = MDictLibraryDescriptor(id: UUID(), name: "Book", mdx: reference,
            resources: [], folder: reference, entryCount: 1)
        var configuration = LearningDictionaryConfiguration(enabled: [book.source], libraries: [book])
        #expect(configuration.sources(for: .french) == [book.source], "An unknown book remains manually selectable")
        #expect(configuration.automaticSources(for: .french).isEmpty)
        book.languages = .init(entry: .english, definition: .chinese)
        configuration = .init(enabled: [book.source], libraries: [book])
        #expect(configuration.sources(for: .french).isEmpty)
        #expect(configuration.automaticSources(for: .english) == [book.source])
        book.languages = .init(entry: nil, definition: .english, multilingual: true)
        configuration = .init(enabled: [book.source], libraries: [book])
        #expect(configuration.automaticSources(for: .french) == [book.source])
    }
}
