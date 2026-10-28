import Foundation
import Testing
@testable import Lingrove

@Suite(.serialized)
struct VocabularyUnknownLanguageTests {
    @Test func unknownEntryAndContextSurviveSQLiteReopenBackupAndPortableExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let text = "OpenAI-compatible chat endpoint"
        var example = VocabularyPolicy.example(text: text, ranges: [(text as NSString).range(of: "compatible")],
            language: nil, startsAtBoundary: false, endsAtBoundary: false)
        example?.meaning = "兼容的"; example?.translation = "兼容 OpenAI 的聊天端点"
        let unknown = VocabularyCapture(expression: "compatible", dictionaryForm: "compatible", language: nil,
            kind: .word, meaning: "兼容的", meaningLanguage: .chinese, example: example)
        let archive = VocabularyArchive(url: url)
        let saved = try await archive.save(unknown)
        #expect(saved.document.schemaVersion == VocabularyDocument.currentVersion)
        let entry = try #require(saved.document.entries.first)
        #expect(entry.language == nil && entry.examples.first?.text == text)
        #expect(entry.examples.first?.ranges == example?.ranges)
        #expect(entry.examples.first?.completeness == .fragment)
        let reopened = try await VocabularyArchive(url: url).load()
        #expect(reopened.document == saved.document)
        let known = VocabularyCapture(expression: "compatible", dictionaryForm: "compatible", language: .english,
            kind: .word, meaning: "兼容的", meaningLanguage: .chinese)
        #expect(VocabularyPolicy.entryKey(known) != VocabularyPolicy.entryKey(unknown))
        let both = try await archive.save(known)
        #expect(both.document.entries.count == 2)

        let backup = folder.appendingPathComponent("backup.json")
        try await archive.backup(to: backup)
        let restored = try await VocabularyArchive(url: folder.appendingPathComponent("restored.sqlite")).restore(from: backup)
        #expect(restored.document == both.document)
        let exported = VocabularyExportPolicy.document(both.document.entries, configuration: .init())
        #expect(exported.version == 2)
        let decoded = try JSONDecoder().decode(VocabularyExportDocument.self, from: JSONEncoder().encode(exported))
        #expect(decoded.entries.contains { $0.language == nil })

        _ = try await archive.remove(unknown)
        let afterRemoval = try await VocabularyArchive(url: url).load()
        #expect(afterRemoval.document.schemaVersion == VocabularyDocument.currentVersion)
        #expect(afterRemoval.document.collectedEntries.count == 1 && afterRemoval.document.collectedEntries[0].language == .english)
    }

    @Test func currentFormatRetainsKnownLanguagesAndRejectsOldPayloads() async throws {
        let archive = VocabularyArchive(url: nil)
        let saved = try await archive.save(.init(expression: "word", dictionaryForm: "word", language: .english, kind: .word))
        let decoded = try JSONDecoder().decode(VocabularyDocument.self, from: JSONEncoder().encode(saved.document))
        #expect(decoded == saved.document && decoded.schemaVersion == VocabularyDocument.currentVersion)
        #expect(VocabularyExportPolicy.document(decoded.entries, configuration: .init()).version == 1)
        var invalid = VocabularyDocument()
        _ = try VocabularyPolicy.save(.init(expression: "word", dictionaryForm: "word", language: nil, kind: .word),
            in: &invalid, now: Date())
        invalid.schemaVersion = 3
        await #expect(throws: VocabularyError.self) { try await archive.validate(invalid) }
    }

    @Test func csvUndLanguageDoesNotSilentlyBecomeTheImportDefault() throws {
        let table = try VocabularyWordListPolicy.decode(Data("expression,language\ncompatible,und\n".utf8), fileExtension: "csv")
        let inputs = try VocabularyWordListPolicy.inputs(table,
            configuration: VocabularyWordListPolicy.configuration(for: table, language: .english))
        #expect(inputs.count == 1 && inputs[0].language == nil)
        let plan = try VocabularyEntryInputPolicy.plan(inputs, into: .init(), now: Date())
        #expect(plan.document.schemaVersion == VocabularyDocument.currentVersion)
    }
}
