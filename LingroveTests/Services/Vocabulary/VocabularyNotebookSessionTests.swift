import Combine
import Foundation
import Testing
@testable import Lingrove

/// The library borrows the same provider configuration as a floating card. Browsing entries is
/// idle; only the explicit reference disclosure performs a dictionary operation.
@MainActor
struct VocabularyNotebookSessionTests {
    @Test func perExampleSessionsStaySeparateAndDictionaryLookupIsLazy() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        for sentence in ["Let me know.", "I know the answer."] {
            await store.save(.init(expression: "know", dictionaryForm: "know", language: .english, kind: .word,
                example: VocabularyPolicy.example(text: sentence, ranges: [(sentence as NSString).range(of: "know")], language: .english)))
        }
        let entry = try #require(store.entries.first)
        let provider = NotebookDictionaryProbe()
        let domain = "VocabularyNotebookSessionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = LearningDictionarySettings(defaults: defaults)
        settings.reset()
        // Automatic source priority follows the requested definition language. This test pins
        // English rather than letting the Mac's preferred language reorder the fixture calls.
        settings.setDefinitionLanguage(.english)
        let learning = VocabularyNotebookSession(provider: provider, settings: settings)
        learning.select(entry, senseID: entry.senses[0].id)
        #expect(learning.explanations.count == 1 && learning.dictionary.unit == nil)
        #expect(await provider.calls.isEmpty)
        for example in entry.senses[0].examples {
            let session = try #require(learning.explanations[example.id.uuidString])
            #expect(session.input?.context == example.text && !session.isGenerating)
        }
        let firstSession = try #require(learning.explanations.values.first)
        learning.select(entry, senseID: entry.senses[1].id)
        #expect(learning.senseID == entry.senses[1].id && learning.explanations.count == 1)
        #expect(learning.explanations[entry.senses[0].examples[0].id.uuidString] == nil)
        #expect(!firstSession.isGenerating)
        learning.showDictionary(entry)
        await settle { learning.dictionary.content != .loading }
        #expect(await provider.calls == [.bundled])
        learning.dictionary.selectSource(.system)
        await settle { learning.dictionary.content == .result(.systemText("System live entry")) }
        #expect(await provider.calls == [.bundled, .system])
        #expect(learning.explanations.values.allSatisfy { !$0.isGenerating })
        learning.hideDictionary()
        #expect(learning.dictionary.unit == nil)
        learning.select(nil)
        #expect(learning.explanations.isEmpty)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<200 where !predicate() { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }
}

private actor NotebookDictionaryProbe: LearningDictionaryProviding {
    var calls: [LearningDictionarySource] = []
    func lookup(_ query: String, language: LearningLanguage?, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        calls.append(source)
        return .systemText(source == .system ? "System live entry" : "Built-in live entry")
    }
}
