import Combine
import Foundation
import Testing
@testable import Cotabby

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
        let learning = VocabularyNotebookSession(provider: provider)
        learning.select(entry)
        #expect(learning.explanations.count == 2 && learning.dictionary.unit == nil)
        #expect(await provider.calls.isEmpty)
        for example in entry.examples {
            let session = try #require(learning.explanations[example.id.uuidString])
            #expect(session.input?.context == example.text && !session.isGenerating)
        }
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
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        calls.append(source)
        return .systemText(source == .system ? "System live entry" : "Built-in live entry")
    }
}
