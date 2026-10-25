import Foundation
import Testing
@testable import Lingrove

struct VocabularyEntryImportTests {
    @Test func manualAdditionPersistsAndGroupsDifferentMeaningsWithoutReplacingContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: file)
        let first = VocabularyEntryInput(expression: " bank ", language: .english,
            meaning: "financial institution", note: "Keep this note", tags: ["Work", "Work"])
        let (initial, result) = try await archive.addEntries([first])
        let entry = try #require(initial.document.entries.first)
        #expect(result.addedEntries == 1 && result.addedSenses == 1)
        #expect(entry.expression == "bank" && entry.dictionaryForm == "bank")
        #expect(entry.senses[0].meaningOrigin == .user && entry.senses[0].tags == ["Work"])
        let (next, added) = try await archive.addEntries([.init(expression: "bank", meaning: "river edge")])
        #expect(added.addedEntries == 0 && added.addedSenses == 1)
        #expect(next.document.entries[0].senses[0] == entry.senses[0])
        #expect(next.document.entries[0].senses.count == 2)
        #expect(try await VocabularyArchive(url: file).load().document == next.document)
    }

    @Test func duplicateRowsAndBareWordListsDoNotCreateBlankSensesOrTouchRevisions() async throws {
        let archive = VocabularyArchive(url: nil)
        let input = VocabularyEntryInput(expression: "bank", meaning: "河岸", meaningLanguage: .chinese)
        let (initial, _) = try await archive.addEntries([input])
        let (next, result) = try await archive.addEntries([input, .init(expression: "bank", meaning: "河岸"), .init(expression: "bank")])
        #expect(result.skippedRows == 3 && result.addedSenses == 0)
        #expect(next.revision == initial.revision && next.document == initial.document)
        #expect(result.selection?.senseID == initial.document.entries[0].senses[0].id)
    }

    @Test func invalidLastRowRollsBackTheEntireBatchAndCancellationCannotCommit() async throws {
        let archive = VocabularyArchive(url: nil)
        let initial = try await archive.load()
        #expect(throws: VocabularyWordListError.self) {
            try VocabularyEntryInputPolicy.plan([.init(expression: "hello"), .init(expression: "")],
                into: initial.document, now: Date())
        }
        do {
            _ = try await archive.addEntries([.init(expression: "hello"), .init(expression: "")])
            Issue.record("An invalid row must block the whole batch")
        } catch is VocabularyWordListError { }
        #expect(try await archive.load().revision == initial.revision)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await archive.addEntries([.init(expression: "cancelled")])
        }
        do { _ = try await cancelled.value; Issue.record("A cancelled task must not write") } catch is CancellationError { }
        #expect(try await archive.load().document.entries.isEmpty)
    }

    @Test func preservedStandaloneTranslationsAndMergedMeaningsAreAlsoDuplicates() async throws {
        let archive = VocabularyArchive(url: nil)
        var document = try await archive.addEntries([.init(expression: "abandon", meaning: "give up")]).0.document
        document.entries[0].senses[0].standaloneMeanings = [.init(text: "放弃", language: .chinese)]
        document.entries[0].senses[0].alternateMeanings = [.init(text: "forsake", language: .english)]
        _ = try await archive.commit(document)
        let (next, result) = try await archive.addEntries([
            .init(expression: "abandon", meaning: "放弃", meaningLanguage: .chinese),
            .init(expression: "abandon", meaning: "forsake", meaningLanguage: .english)
        ])
        #expect(result.skippedRows == 2 && result.addedSenses == 0)
        #expect(next.document == document)
    }

    @Test @MainActor func generalExplanationsStayWithTheirExplicitSenseAndSurviveMergeAndReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: file)
        _ = try await archive.save(.init(expression: "bank", dictionaryForm: "bank", language: .english,
            kind: .word, meaning: "legacy favorite"))
        let (initial, _) = try await archive.addEntries([
            .init(expression: "bank", meaning: "river edge"), .init(expression: "bank", meaning: "financial institution")
        ])
        let entry = try #require(initial.document.entries.first)
        let first = entry.senses[1], second = entry.senses[2]
        #expect(first.supportsGeneralExplanation && !first.isSavedWithoutContext)
        let session = VocabularyNotebookSession(provider: LearningLexiconService(resourceURL: nil))
        session.select(entry, senseID: first.id)
        #expect(session.explanations["standalone"] != nil)
        let records = [first, second].map { sense in
            LearningExplanationRecord(id: UUID(),
                input: LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, sense: sense, example: nil)),
                language: .english, result: .init(meaning: "Proposed meaning", explanation: "A general explanation."),
                model: "fixture", createdAt: Date())
        }
        #expect(records[0].input != records[1].input)
        let saved = try await archive.saveExplanation(records[0])
        #expect(saved.document.entries[0].senses[0].explanations.isEmpty)
        #expect(saved.document.entries[0].senses[1].explanations == [records[0]])
        #expect(saved.document.entries[0].senses[2].explanations.isEmpty)
        #expect(saved.document.entries[0].senses[1].meaning == "river edge")
        _ = try await archive.saveExplanation(records[1])
        let merged = try await archive.mergeSenses(entryID: entry.id, source: second.id, target: first.id)
        let survivor = try #require(merged.document.entries[0].senses.first { $0.id == first.id })
        #expect(Set(survivor.explanations.map(\.id)) == Set(records.map(\.id)))
        #expect(survivor.explanations.allSatisfy { $0.input.occurrenceIdentity == "sense:" + first.id.uuidString })
        #expect(try await VocabularyArchive(url: file).load().document == merged.document)
        let legacyMerge = try await archive.mergeSenses(entryID: entry.id, source: first.id, target: entry.senses[0].id)
        let legacy = try #require(legacyMerge.document.entries[0].senses.first)
        #expect(legacy.isSavedWithoutContext && legacy.explanations.allSatisfy { $0.input.occurrenceIdentity == nil })
        let legacyInput = LearningExplanationPolicy.input(LearningExplanationPolicy.capture(legacyMerge.document.entries[0],
            sense: legacy, example: nil))
        #expect(legacyInput.occurrenceIdentity == nil)
    }

    @Test func confirmationReplansAgainstOtherWritersAndPreservesCapturedUsages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: file), other = VocabularyArchive(url: file)
        let table = try VocabularyWordListPolicy.decode(Data("bank,river edge\nhello,a greeting".utf8), fileExtension: "csv")
        let preview = try await archive.previewWordList(table, configuration: .init(columns: [.expression: 0, .meaning: 1]))
        #expect(preview.result.addedEntries == 2)
        let capture = VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            example: VocabularyPolicy.example(text: "The bank opens early.", ranges: [.init(location: 4, length: 4)], language: .english))
        let saved = try await other.save(capture)
        let oldSense = try #require(saved.document.entries.first?.senses.first)
        let (final, result) = try await archive.addEntries(preview.inputs)
        #expect(result.addedEntries == 1 && result.addedSenses == 2)
        #expect(final.document.entries.first { $0.expression == "bank" }?.senses.first == oldSense)
        #expect(final.document.entries.count == 2)
    }

    @Test @MainActor func previewAndCancelAreReadOnlyAndConfigurationInvalidatesOldInputsImmediately() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("list.csv")
        try Data("expression,meaning\nhello,a greeting".utf8).write(to: file)
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let session = VocabularyWordListImportSession(store: store)
        await session.load(file, language: .english)
        for _ in 0..<200 where session.preparing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.preview?.inputs.first?.meaning == "a greeting")
        #expect(store.entries.isEmpty)
        session.configuration.language = .spanish
        #expect(session.preview == nil && session.preparing)
        #expect(await session.commit() == nil)
        for _ in 0..<200 where session.preparing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.preview?.inputs.first?.language == .spanish)
        session.cancel()
        #expect(await session.commit() == nil && store.entries.isEmpty)
    }
}
