import Foundation
import Testing
@testable import Cotabby

/// Both collection orders pass through the real store/archive. These cases protect semantic
/// ownership and occurrence identity without touching the user's notebook or a model runtime.
@MainActor
struct VocabularyContextualMeaningTests {
    private func capture(_ sentence: String = "Please keep me posted.") -> VocabularyCapture {
        .init(expression: "keep someone posted", dictionaryForm: "keep someone posted", language: .english, kind: .pattern,
            example: VocabularyPolicy.example(text: sentence,
                ranges: ["keep", "posted"].map { (sentence as NSString).range(of: $0) }, language: .english))
    }
    private func record(_ capture: VocabularyCapture, meaning: String = "随时告知最新进展") -> LearningExplanationRecord {
        .init(id: UUID(), input: LearningExplanationPolicy.input(capture), language: .chinese,
            result: .init(meaning: meaning, explanation: "keep + 宾语 + posted 表示持续告知。"), model: "fixture", createdAt: Date())
    }

    @Test(arguments: [false, true])
    func collectionBeforeOrAfterExplanationProducesTheSameSavedUsage(_ explainFirst: Bool) async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let capture = capture(), record = record(capture)
        if explainFirst {
            store.enrichCapture = { capture in var enriched = capture; enriched.explanation = record; return enriched }
        }
        await store.save(capture)
        if !explainFirst { await store.saveExplanation(record) }
        let entry = try #require(store.entries.first)
        #expect(entry.examples.count == 1 && store.contains(capture))
        #expect(entry.examples[0].meaning == record.result.meaning && entry.examples[0].meaningOrigin == .ai)
        #expect(entry.examples[0].meaningLanguage == .chinese && entry.explanations == [record])
        #expect(entry.senses[0].meaning.isEmpty, "A contextual sense belongs to the occurrence, not a universal word definition")
        await store.save(capture)
        #expect(store.entries[0].examples.count == 1 && store.contains(capture))
        await store.remove(capture)
        #expect(store.entries.isEmpty)
    }

    @Test func refreshingDraftsPreservesUserEditsAndOtherOccurrences() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let first = capture(), second = capture("They keep us posted.")
        await store.save(first); await store.save(second)
        await store.saveExplanation(record(first))
        let next = record(first, meaning: "持续通知")
        await store.saveExplanation(next)
        var baseline = try #require(store.entries.first)
        #expect(baseline.examples[0].meaning == "持续通知" && baseline.examples[1].meaning.isEmpty)
        var edited = baseline
        edited.senses[0].examples[0].meaning = "My preferred wording"
        #expect(await store.update(edited, basedOn: baseline))
        baseline = try #require(store.entries.first)
        #expect(baseline.examples[0].meaningOrigin == .user)
        let newer = record(first, meaning: "新的 AI 释义")
        await store.saveExplanation(newer)
        await store.saveExplanation(record(second, meaning: "另一条语境释义"))
        let current = store.entries[0]
        #expect(current.examples[0].meaning == "My preferred wording" && current.examples[0].meaningOrigin == .user)
        #expect(current.examples[1].meaning == "另一条语境释义")
        #expect(current.explanations?.contains(newer) == true)
        #expect(store.contains(first) && store.contains(second))
    }

    @Test func editingSourceClearsAnAutomaticSenseWithoutCreatingAUserOwnedBlank() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let original = capture()
        await store.save(original); await store.saveExplanation(record(original))
        let baseline = try #require(store.entries.first)
        var edited = baseline
        let sentence = "They keep us posted."
        edited.senses[0].examples[0].text = sentence
        edited.senses[0].examples[0].ranges = ["keep", "posted"].map { VocabularyTextRange((sentence as NSString).range(of: $0)) }
        edited.senses[0].examples[0].meaning = ""
        edited.senses[0].examples[0].meaningLanguage = nil
        edited.senses[0].examples[0].meaningOrigin = .captured
        #expect(await store.update(edited, basedOn: baseline))
        let current = store.entries[0]
        let fresh = LearningExplanationPolicy.capture(current, example: current.examples[0])
        await store.saveExplanation(record(fresh, meaning: "新语境的含义"))
        #expect(store.entries[0].examples[0].meaning == "新语境的含义")
        #expect(store.entries[0].examples[0].meaningOrigin == .ai)
    }

    @Test func resavingStandaloneDoesNotOverwriteAUserMeaningOrDuplicateAnExample() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let withContext = capture()
        var standalone = withContext; standalone.example = nil; standalone.meaning = "Captured draft"
        await store.save(withContext); await store.save(standalone)
        let baseline = try #require(store.entries.first)
        var edited = baseline; edited.senses[1].meaning = "User meaning"
        #expect(await store.update(edited, basedOn: baseline))
        await store.save(standalone); await store.save(standalone)
        #expect(store.entries[0].senses[1].meaning == "User meaning" && store.entries[0].senses[1].meaningOrigin == .user)
        #expect(store.entries[0].examples.count == 1)
    }

    @Test func annotationLanguageDoesNotCreateAnotherSenseOrUsage() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        var first = capture(), second = capture()
        first.example?.translationLanguage = .chinese
        second.example?.translationLanguage = .spanish
        await store.save(first); await store.save(second)
        await store.saveExplanation(record(first))
        #expect(store.entries[0].senses.count == 1 && store.entries[0].examples.count == 1)
        #expect(store.entries[0].examples[0].meaningOrigin == .ai)
    }

    @Test func completeAndFragmentReceiptsRetainTheirOwnExplanationScope() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        var fragment = capture(); fragment.example?.completeness = .fragment
        let complete = capture()
        await store.save(fragment); await store.save(complete)
        let partial = record(fragment, meaning: "片段中的可能含义")
        let precise = record(complete, meaning: "完整句中的含义")
        await store.saveExplanation(partial); await store.saveExplanation(precise)
        let entry = try #require(store.entries.first)
        #expect(entry.examples.count == 2 && entry.explanations?.count == 2)
        #expect(entry.examples[0].meaning == partial.result.meaning && entry.examples[1].meaning == precise.result.meaning)
        #expect(store.contains(fragment) && store.contains(complete))
    }

    @Test func aTargetWithoutContextIsSavedAsAGeneralMeaning() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        var generic = capture(); generic.example = nil
        let result = record(generic, meaning: "通常表示持续告知")
        #expect(result.input.contextKind == .none)
        await store.save(generic); await store.saveExplanation(result)
        let entry = try #require(store.entries.first)
        #expect(entry.examples.isEmpty && entry.senses[0].isSavedWithoutContext)
        #expect(entry.senses[0].meaning == result.result.meaning && entry.senses[0].meaningOrigin == .ai)
        #expect(entry.explanations == [result])
    }

    @Test func wholeSentenceExplanationDoesNotReplaceItsTranslation() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let sentence = "Please keep me posted."
        var example = VocabularyPolicy.example(text: sentence, ranges: [NSRange(location: 0, length: sentence.utf16.count)],
            language: .english)
        example?.translation = "请随时告诉我最新进展。"
        let capture = VocabularyCapture(expression: sentence, dictionaryForm: sentence, language: .english, kind: .sentence,
            example: example)
        await store.save(capture)
        await store.saveExplanation(record(capture))
        let entry = try #require(store.entries.first)
        #expect(entry.examples[0].meaning == record(capture).result.meaning && entry.examples[0].translation == example?.translation)
        #expect(entry.explanations?.count == 1)
    }
}
