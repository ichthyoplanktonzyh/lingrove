import Foundation
import Testing
@testable import Cotabby

/// Real archive transactions exercise identity and ownership without a model, a dictionary
/// service or user data. Labels are deliberately varied so wording cannot become an ID.
@MainActor
struct VocabularySenseTests {
    private func capture(_ sentence: String, translation: String = "", language: LearningLanguage = .chinese) -> VocabularyCapture {
        var example = VocabularyPolicy.example(text: sentence, ranges: [(sentence as NSString).range(of: "bank")], language: .english)
        example?.translation = translation
        example?.translationLanguage = language
        return .init(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word, example: example)
    }

    private func record(_ capture: VocabularyCapture, meaning: String, language: LearningLanguage = .chinese) -> LearningExplanationRecord {
        .init(id: UUID(), input: LearningExplanationPolicy.input(capture), language: language,
            result: .init(meaning: meaning, explanation: "An explanation of this captured usage."), model: "fixture", createdAt: Date())
    }

    @Test func newContextsDoNotMergeBecauseGeneratedWordsMatch() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let first = capture("I went to the bank."), second = capture("We sat beside the bank.")
        await store.save(first); await store.save(second)
        await store.saveExplanation(record(first, meaning: "Same wording"))
        await store.saveExplanation(record(second, meaning: "Same wording"))
        let entry = try #require(store.entries.first)
        #expect(entry.senses.count == 2 && Set(entry.senses.map(\.id)).count == 2)
        #expect(entry.senses.allSatisfy { $0.meaning.isEmpty }, "A contextual answer is owned by its usage")
        #expect(entry.senses.allSatisfy { $0.examples.count == 1 })
    }

    @Test func translationAndExplanationVariantsKeepOneUsageAndItsSense() async throws {
        let archive = VocabularyArchive(url: nil), store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let chinese = capture("I went to the bank.", translation: "我去了银行。")
        let japanese = capture("I went to the bank.", translation: "銀行に行きました。", language: .japanese)
        await store.save(chinese)
        let original = try #require(store.entries.first)
        await store.save(japanese)
        await store.saveExplanation(record(chinese, meaning: "银行"))
        await store.saveExplanation(record(japanese, meaning: "A financial institution", language: .english))
        let entry = try #require(store.entries.first)
        #expect(entry.senses[0].id == original.senses[0].id)
        #expect(entry.examples.count == 1 && entry.examples[0].id == original.examples[0].id)
        #expect(entry.examples[0].translationVariants.map(\.text) == ["我去了银行。", "銀行に行きました。"])
        #expect(Set(entry.examples[0].explanations.map(\.language)) == [.chinese, .english])
        #expect(store.contains(chinese) && store.contains(japanese))
        // Persistence uses the nested representation rather than flattened computed projections.
        let snapshot = try await archive.save(chinese)
        let data = try JSONEncoder().encode(snapshot.document)
        #expect(try JSONDecoder().decode(VocabularyDocument.self, from: data) == snapshot.document)
    }

    @Test func regenerationKeepsCoreMeaningAndAllStableIDs() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil)), capture = capture("I went to the bank.")
        await store.save(capture)
        let baseline = try #require(store.entries.first)
        var edited = baseline
        edited.senses[0].meaning = "A financial institution"
        edited.senses[0].examples[0].meaning = "User's contextual wording"
        #expect(await store.update(edited, basedOn: baseline))
        await store.saveExplanation(record(capture, meaning: "一家银行"))
        let entry = try #require(store.entries.first)
        #expect(entry.id == baseline.id && entry.senses[0].id == baseline.senses[0].id)
        #expect(entry.examples[0].id == baseline.examples[0].id)
        #expect(entry.senses[0].meaning == "A financial institution" && entry.senses[0].meaningOrigin == .user)
        #expect(entry.examples[0].meaning == "User's contextual wording" && entry.examples[0].meaningOrigin == .user)
        #expect(entry.examples[0].explanations.count == 1)
    }

    @Test func mergePreservesAliasesAnnotationsAndUsageIDsAcrossReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook-v3.json")
        let archive = VocabularyArchive(url: url)
        let first = capture("I went to the bank."), second = capture("The bank opened early.")
        _ = try await archive.save(first); _ = try await archive.save(second)
        let baseline = try #require(try await archive.load().document.entries.first)
        var edited = baseline
        edited.senses[0].meaning = "银行"; edited.senses[1].meaning = "金融机构"
        edited.senses[0].note = "First note"; edited.senses[1].note = "Second note"
        edited.senses[0].tags = ["Work"]; edited.senses[1].tags = ["Money"]
        _ = try await archive.update(edited, basedOn: baseline)
        _ = try await archive.saveExplanation(record(first, meaning: "银行"))
        _ = try await archive.saveExplanation(record(second, meaning: "金融机构"))
        let source = baseline.senses[1].id, target = baseline.senses[0].id
        _ = try await archive.mergeSenses(entryID: baseline.id, source: source, target: target)
        let entry = try #require(try await VocabularyArchive(url: url).load().document.entries.first)
        #expect(entry.senses.count == 1 && entry.senses[0].id == target)
        #expect(entry.senses[0].mergedFrom == [source] && VocabularySensePolicy.index(source, in: entry) == 0)
        #expect(Set(entry.examples.map(\.id)) == Set(baseline.examples.map(\.id)))
        #expect(entry.senses[0].note.contains("First note") && entry.senses[0].note.contains("Second note"))
        #expect(Set(entry.senses[0].tags) == ["Work", "Money"])
        #expect(entry.explanations?.count == 2 && entry.senses[0].alternateMeanings.contains(.init(text: "金融机构", language: nil)))
        #expect(VocabularyPolicy.matches(entry, query: "金融机构"))
    }

    @Test func movedUsageReceivesLateExplanationAndOldDestinationResolvesItsCurrentOwner() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let first = capture("I went to the bank."), second = capture("The bank opened early.")
        await store.save(first); await store.save(second)
        let entry = try #require(store.entries.first)
        let destination = try #require(store.explanationDestination(first))
        let usage = try #require(entry.examples.first)
        let result = record(first, meaning: "银行")
        #expect(await store.moveExample(entryID: entry.id, exampleID: usage.id, source: entry.senses[0].id,
            target: entry.senses[1].id))
        await store.saveExplanation(result)
        #expect(store.entries[0].senses[0].examples.isEmpty)
        #expect(store.entries[0].senses[1].examples.contains { $0.id == usage.id && $0.explanations == [result] })
        #expect(await store.adoptExplanation(result, at: destination))
        #expect(store.entries[0].senses[1].examples.first { $0.id == usage.id }?.meaningOrigin == .user)
        var opened: VocabularySelection?
        store.openSelection = { opened = $0 }
        store.show(first)
        #expect(opened == .init(entryID: entry.id, senseID: entry.senses[1].id))
    }

    @Test func movingToANewSenseAndDeletingTheUsageCannotResurrectItsOldOwner() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil)), capture = capture("We sat beside the bank.")
        await store.save(capture)
        let entry = try #require(store.entries.first), result = record(capture, meaning: "河岸")
        #expect(await store.moveExample(entryID: entry.id, exampleID: entry.examples[0].id, source: entry.senses[0].id, target: nil))
        let destination = try #require(store.explanationDestination(capture))
        #expect(destination.senseID != entry.senses[0].id && store.entries[0].senses.count == 2)
        #expect(await store.removeSense(entryID: entry.id, senseID: destination.senseID))
        await store.saveExplanation(result)
        #expect(store.entries[0].senses.count == 1 && store.entries[0].examples.isEmpty)
        #expect(!(await store.adoptExplanation(result, at: destination)))
    }

    @Test func invalidOwnershipCannotReplaceTheLastGoodArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook-v3.json")
        let archive = VocabularyArchive(url: url)
        let snapshot = try await archive.save(capture("I went to the bank."))
        let baseline = try #require(snapshot.document.entries.first)
        var edited = baseline
        edited.senses.append(edited.senses[0])
        await #expect(throws: (any Error).self) { try await archive.update(edited, basedOn: baseline) }
        #expect(try await VocabularyArchive(url: url).load().document == snapshot.document)
    }

    @Test func separateSchemaThreeFileLeavesTheRetiredArchiveUntouched() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("notebook.json"), bytes = Data("retired schema two data".utf8)
        try bytes.write(to: old)
        let archive = VocabularyArchive(url: folder.appendingPathComponent("notebook-v3.json"))
        #expect(try await archive.load().document.entries.isEmpty)
        _ = try await archive.save(capture("I went to the bank."))
        #expect(try Data(contentsOf: old) == bytes)
    }

    @Test func concurrentSavesKeepBothTranslationsWithoutDuplicatingTheUsage() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let first = capture("I went to the bank.", translation: "我去了银行。")
        let second = capture("I went to the bank.", translation: "銀行に行きました。", language: .japanese)
        async let one: Void = store.save(first)
        async let two: Void = store.save(second)
        _ = await (one, two)
        #expect(store.entries.count == 1 && store.entries[0].examples.count == 1)
        #expect(Set(store.entries[0].examples[0].translationVariants.map(\.text)) == ["我去了银行。", "銀行に行きました。"])
        #expect(!store.isPending(first) && !store.isPending(second))
    }

    @Test func conflictingOccurrencesFailClosedWithoutLosingEitherIdentity() async throws {
        let archive = VocabularyArchive(url: nil)
        _ = try await archive.save(capture("I went to the bank."))
        let snapshot = try await archive.save(capture("The bank opened early."))
        let baseline = try #require(snapshot.document.entries.first)
        var invalid = baseline
        invalid.senses[1].examples[0].text = invalid.examples[0].text
        invalid.senses[1].examples[0].ranges = invalid.examples[0].ranges
        let source = invalid.senses[0].id, target = invalid.senses[1].id, usage = invalid.examples[0].id
        #expect(throws: VocabularyError.editConflict) {
            _ = try VocabularySensePolicy.move(exampleID: usage, from: source, to: target, in: &invalid, now: Date())
        }
        #expect(throws: VocabularyError.editConflict) {
            try VocabularySensePolicy.merge(source: source, into: target, in: &invalid, now: Date())
        }
        await #expect(throws: (any Error).self) { try await archive.update(invalid, basedOn: baseline) }
        #expect(try await archive.load().document == snapshot.document)
    }

    @Test func aStaleDeleteForAMergedAliasCannotDeleteTheSurvivingSense() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.save(capture("I went to the bank.")); await store.save(capture("The bank opened early."))
        let entry = try #require(store.entries.first), source = entry.senses[0].id, target = entry.senses[1].id
        #expect(await store.mergeSenses(entryID: entry.id, source: source, target: target))
        #expect(!(await store.removeSense(entryID: entry.id, senseID: source)))
        #expect(store.entries[0].senses.count == 1 && store.entries[0].senses[0].id == target)
    }

    @Test func aStaleMergeCannotBroadenItsSourceThroughAnAlias() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        for text in ["I went to the bank.", "The bank opened early.", "We sat beside the bank."] {
            await store.save(capture(text))
        }
        let entry = try #require(store.entries.first)
        let first = entry.senses[0].id, second = entry.senses[1].id, third = entry.senses[2].id
        #expect(await store.mergeSenses(entryID: entry.id, source: first, target: second))
        #expect(!(await store.mergeSenses(entryID: entry.id, source: first, target: third)))
        #expect(store.entries[0].senses.map(\.id) == [second, third])
        #expect(store.entries[0].senses[0].examples.count == 2 && store.entries[0].senses[1].examples.count == 1)
        #expect(VocabularyPolicy.matches(store.entries[0], query: "bank"))
    }

    @Test func unitKindNeverRedirectsAnExplanationToAnotherEntry() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil)), word = capture("I went to the bank.")
        let expression = VocabularyCapture(expression: word.expression, dictionaryForm: word.dictionaryForm,
            language: word.language, kind: .expression, example: word.example)
        await store.save(word); await store.save(expression)
        let result = record(expression, meaning: "A financial institution")
        await store.saveExplanation(result)
        #expect(store.entries.count == 2)
        #expect(store.entries.first { $0.kind == .word }?.explanations == nil)
        #expect(store.entries.first { $0.kind == .expression }?.explanations == [result])
    }
}
