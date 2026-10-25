import Foundation
import Testing
@testable import Lingrove

/// Real archive transactions exercise context import without models, networking or user data.
/// Sentence identity, translation preservation and destination ownership must survive reopen.
struct VocabularyExampleImportTests {
    @Test func CSVRecognizesExamplesWithoutRelabelingLegacyWordTranslations() throws {
        for header in ["expression,meaning,example,translation", "词条,释义,例句,例句译文"] {
            let table = try decode(header + "\nbank,河岸,We sat by the bank.,我们坐在河岸边。")
            let config = VocabularyWordListPolicy.configuration(for: table, language: .english)
            #expect(config.columns[.meaning] == 1 && config.columns[.example] == 2 && config.columns[.exampleTranslation] == 3)
            let value = try #require(VocabularyWordListPolicy.inputs(table, configuration: config).first)
            #expect(value.meaning == "河岸" && value.example == "We sat by the bank." && value.exampleTranslation == "我们坐在河岸边。")
        }
        let legacy = try decode("expression,translation\nbank,河岸")
        let old = VocabularyWordListPolicy.configuration(for: legacy, language: .english)
        #expect(old.columns[.meaning] == 1 && old.columns[.exampleTranslation] == nil)
        let explicit = try decode("expression,translation,example,example_translation\nbank,河岸,The bank is steep.,河岸很陡。")
        let mapping = VocabularyWordListPolicy.configuration(for: explicit, language: .english)
        #expect(mapping.columns[.meaning] == 1 && mapping.columns[.exampleTranslation] == 3)
        let simple = try decode("word,sentence,translation\nbank,The bank is steep.,河岸很陡。")
        let simpleMap = VocabularyWordListPolicy.configuration(for: simple, language: .english)
        #expect(simpleMap.columns[.meaning] == nil && simpleMap.columns[.exampleTranslation] == 2)
    }

    @Test func translationWithoutExampleReportsThePhysicalCSVLine() throws {
        let table = try decode("expression,example,example_translation\nbank,\"The bank\nis steep.\",河岸很陡。\nhello,,你好")
        do {
            _ = try VocabularyWordListPolicy.inputs(table, configuration: VocabularyWordListPolicy.configuration(for: table, language: .english))
            Issue.record("A translation cannot be silently detached from its sentence")
        } catch VocabularyWordListError.missingExample(let line) { #expect(line == 4) }
        #expect(throws: VocabularyWordListError.self) {
            try VocabularyEntryInputPolicy.validated(.init(expression: "hello", exampleTranslation: "你好"))
        }
        #expect(throws: VocabularyWordListError.self) {
            try VocabularyEntryInputPolicy.validated(.init(expression: "hello", example: String(repeating: "a", count: 262_145)))
        }
    }

    @Test func wholeSentencesTranslationsAndUnicodeHighlightsSurviveReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = VocabularyArchive(url: folder.appendingPathComponent("notebook.sqlite"))
        let text = "👩🏽‍💻 We met at the café.\nThe café was quiet."
        let (saved, result) = try await archive.addEntries([.init(expression: "café", meaning: "coffee shop",
            meaningLanguage: .english, example: text, exampleTranslation: "我们在咖啡馆见面。\n咖啡馆很安静。")])
        let usage = try #require(saved.document.entries.first?.examples.first)
        #expect(result.addedEntries == 1 && result.addedSenses == 1 && result.addedExamples == 1 && result.addedTranslations == 1)
        #expect(usage.text == text && usage.translation == "我们在咖啡馆见面。\n咖啡馆很安静。")
        #expect(usage.ranges.count == 2 && usage.ranges.allSatisfy { VocabularyPolicy.valid($0.nsRange, in: text) })
        #expect(usage.translationLanguage == nil && usage.appBundleIdentifier == nil)
        #expect(saved.document.entries[0].senses[0].createdWithoutContext != true)
        #expect(try await VocabularyArchive(url: folder.appendingPathComponent("notebook.sqlite")).load().document == saved.document)
    }

    @Test func examplesAppendToAnExplicitMeaningWithoutReplacingReviewOrExistingContent() async throws {
        let archive = VocabularyArchive(url: nil)
        let first = VocabularyEntryInput(expression: "bank", meaning: "river edge", note: "Keep this note", tags: ["Water"],
            example: "We sat by the bank.", exampleTranslation: "我们坐在河岸边。")
        let initial = try await archive.addEntries([first]).0
        var document = initial.document
        let id = document.entries[0].senses[0].id
        document.entries[0].senses[0].review = .init(plan: .init(), bindings: [.init(originSenseID: id,
            endpoint: "http://127.0.0.1:8765", profile: "User 1", noteID: 42, model: "Fixture", deck: "Default",
            identityField: "LingroveID", mapping: [.identity: "LingroveID"],
            fields: ["LingroveID": id.uuidString.lowercased()])])
        _ = try await archive.commit(document)
        var second = first; second.example = "The bank is steep."; second.exampleTranslation = "河岸很陡。"
        let (next, result) = try await archive.addEntries([second, second])
        let sense = try #require(next.document.entries.first?.senses.first)
        #expect(result.addedEntries == 0 && result.addedSenses == 0 && result.addedExamples == 1 && result.skippedRows == 1)
        #expect(result.hasChanges && sense.id == id && sense.examples.count == 2)
        #expect(sense.review == document.entries[0].senses[0].review)
        #expect(sense.note == first.note && sense.tags == first.tags && sense.meaning == first.meaning)
        #expect(sense.examples[0] == document.entries[0].senses[0].examples[0])
        let (repeated, duplicate) = try await archive.addEntries([first, second])
        #expect(!duplicate.hasChanges && duplicate.skippedRows == 2 && repeated.revision == next.revision)
    }

    @Test func anotherTranslationIsPreservedAsAVariantAndRepeatedImportDoesNotWrite() async throws {
        let archive = VocabularyArchive(url: nil)
        let first = VocabularyEntryInput(expression: "bank", meaning: "river edge",
            example: "The bank is steep.", exampleTranslation: "河岸很陡。")
        let saved = try await archive.addEntries([first]).0
        var translated = first; translated.exampleTranslation = "这段河岸很陡峭。"
        let (next, result) = try await archive.addEntries([translated])
        #expect(result.hasChanges && result.addedSenses == 0 && result.addedExamples == 0 && result.addedTranslations == 1)
        let usage = try #require(next.document.entries.first?.examples.first)
        #expect(usage.id == saved.document.entries[0].examples[0].id && usage.translation == first.exampleTranslation)
        #expect(usage.translationVariants == [.init(text: translated.exampleTranslation, language: nil)])
        let (same, duplicate) = try await archive.addEntries([translated])
        #expect(!duplicate.hasChanges && duplicate.skippedRows == 1 && same.revision == next.revision)
    }

    @Test func newContextsWithoutMeaningsStayIndependentAndUnmatchedTextIsKept() async throws {
        let archive = VocabularyArchive(url: nil)
        let (saved, result) = try await archive.addEntries([
            .init(expression: "bank", example: "The bank opens early."),
            .init(expression: "bank", example: "We sat by the bank."),
            .init(expression: "go", example: "She went home.", exampleTranslation: "她回家了。")
        ])
        #expect(result.addedEntries == 2 && result.addedSenses == 3 && result.addedExamples == 3)
        let bank = try #require(saved.document.entries.first { $0.expression == "bank" })
        #expect(bank.senses.count == 2 && bank.senses.allSatisfy { $0.examples.count == 1 })
        let inflected = try #require(saved.document.entries.first { $0.expression == "go" }?.examples.first)
        #expect(inflected.ranges.isEmpty && inflected.text == "She went home." && inflected.translation == "她回家了。")
    }

    @Test func anExistingUsageCannotBeSilentlyReassignedAndTheWholeBatchRollsBack() async throws {
        let archive = VocabularyArchive(url: nil)
        let first = VocabularyEntryInput(expression: "bank", meaning: "river edge", example: "We sat by the bank.")
        let saved = try await archive.addEntries([first]).0
        var conflict = first; conflict.meaning = "financial institution"
        do {
            _ = try await archive.addEntries([.init(expression: "new word"), conflict])
            Issue.record("An imported example must retain its existing sense owner")
        } catch VocabularyWordListError.exampleConflict { }
        let next = try await archive.load()
        #expect(next.document == saved.document && next.revision == saved.revision)
    }

    @Test @MainActor func exampleOnlyPreviewCanCommitAndUsesTheLatestArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: database), store = VocabularyStore(archive: VocabularyArchive(url: database))
        _ = try await store.addEntries([.init(expression: "bank", meaning: "river edge")])
        let csv = folder.appendingPathComponent("examples.csv")
        try Data("expression,meaning,example,translation\nbank,river edge,The bank is steep.,河岸很陡。".utf8).write(to: csv)
        let session = VocabularyWordListImportSession(store: store)
        await session.load(csv, language: .english)
        for _ in 0..<200 where session.preparing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.preview?.result.addedSenses == 0 && session.preview?.result.addedExamples == 1)
        _ = try await archive.addEntries([.init(expression: "bank", meaning: "river edge", example: "The bank is steep.")])
        let result = try #require(await session.commit())
        #expect(result.hasChanges && result.addedSenses == 0 && result.addedExamples == 0 && result.addedTranslations == 1)
        #expect(store.entries.count == 1 && store.entries[0].examples.count == 1)
        #expect(store.entries[0].examples[0].translation == "河岸很陡。")
    }

    private func decode(_ text: String) throws -> VocabularyWordList {
        try VocabularyWordListPolicy.decode(Data(text.utf8), fileExtension: "csv")
    }

    @Test func repeatedHeadwordRowsUseOneSenseAndStableUsageIdentities() throws {
        let rows = (0..<1_000).map { index in
            VocabularyEntryInput(expression: "bank", meaning: "river edge", example: "We saw bank \(index).")
        }
        let plan = try VocabularyEntryInputPolicy.plan(rows, into: .init(), now: Date())
        let entry = try #require(plan.document.entries.first)
        #expect(plan.result.addedSenses == 1 && plan.result.addedExamples == 1_000 && entry.senses.count == 1)
        #expect(Set(entry.examples.map(\.id)).count == 1_000)
        let again = try VocabularyEntryInputPolicy.plan(rows, into: plan.document, now: Date())
        #expect(!again.result.hasChanges && again.result.skippedRows == 1_000 && again.document == plan.document)
    }
}
