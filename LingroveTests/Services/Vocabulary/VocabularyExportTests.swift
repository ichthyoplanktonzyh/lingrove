import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Isolated learning material contains distinct senses, multilingual text and a shared PNG.
/// Export tests use real encoders, the archive actor and macOS unzip, without Anki or inference.
@Suite(.serialized)
@MainActor
struct VocabularyExportTests {
    func fixture() throws -> (entries: [VocabularyEntry], image: VocabularyPreparedImage) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let image = try VocabularyImageStorage.prepare(VocabularyImageTestFixture.png())
        let usage = VocabularyExample(id: UUID(), text: "The bank said, \"你好\".\nA new line 👩🏽‍💻", translation: "银行打了招呼。",
            translationLanguage: .chinese, ranges: [], completeness: .sentence, meaning: "金融机构",
            meaningLanguage: .chinese, appBundleIdentifier: "private.host.identifier", createdAt: now)
        let first = VocabularySense(id: UUID(), meaning: "银行", meaningLanguage: .chinese,
            note: "A note, with \"quotes\"\r\nand lines", tags: ["finance", "学习"], examples: [usage],
            content: [.init(content: .text(.init(text: "补充文字", bold: true))),
                .init(content: .image(image.reference, caption: "视觉说明"))], createdAt: now, updatedAt: now)
        let second = VocabularySense(id: UUID(), meaning: "河岸", meaningLanguage: .chinese,
            content: [.init(content: .image(image.reference, caption: "另一个义项的图片"))], createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            senses: [first, second], createdAt: now, updatedAt: now)
        let other = VocabularyEntry(id: UUID(), expression: "=1+1", dictionaryForm: "=1+1", language: .english, kind: .expression,
            senses: [.init(id: UUID(), meaning: "公式样式文本", createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
        return ([entry, other], image)
    }

    func selections(_ entries: [VocabularyEntry]) -> [VocabularySelection] {
        entries.flatMap { entry in entry.senses.map { .init(entryID: entry.id, senseID: $0.id) } }
    }

    @Test func scopePreservesMeaningIdentityOrderAndDoesNotExpandRetiredIDs() throws {
        let (entries, _) = try fixture()
        let values = selections(entries)
        let result = try VocabularyExportPolicy.selected(entries, selections: [values[1], values[0], values[1]])
        #expect(result.count == 1)
        #expect(result[0].senses.map(\.id) == [values[1].senseID, values[0].senseID])
        #expect(throws: VocabularyExportError.self) {
            _ = try VocabularyExportPolicy.selected(entries, selections: [.init(entryID: entries[0].id, senseID: UUID())])
        }
        #expect(throws: VocabularyExportError.self) { _ = try VocabularyExportPolicy.selected(entries, selections: []) }
    }

    @Test func csvRoundTripsUnicodeQuotesNewlinesAndIncludesSensesWithoutExamples() throws {
        let (entries, _) = try fixture()
        var options = VocabularyExportConfiguration(); options.format = .csv; options.spreadsheetCompatibility = false
        let package = try VocabularyExportPolicy.package(entries, configuration: options)
        let rows = decodeCSV(String(decoding: package.data, as: UTF8.self))
        #expect(rows.count == 4)
        let header = rows[0]
        func value(_ row: Int, _ field: String) throws -> String { rows[row][try #require(header.firstIndex(of: field))] }
        #expect(try value(1, "example") == entries[0].senses[0].examples[0].text)
        #expect(try value(1, "notes") == entries[0].senses[0].note)
        #expect(try value(1, "meaning") == "银行")
        #expect(try value(1, "contextual_meaning") == "金融机构")
        #expect(try value(2, "meaning") == "河岸")
        #expect(try value(2, "usage_id").isEmpty)
        #expect(try value(3, "expression") == "=1+1")
        #expect(rows.allSatisfy { $0.count == header.count })
        options.spreadsheetCompatibility = true
        let compatible = try VocabularyExportPolicy.package(entries, configuration: options)
        #expect(compatible.data.starts(with: [0xEF, 0xBB, 0xBF]))
        let safe = decodeCSV(String(decoding: compatible.data.dropFirst(3), as: UTF8.self))
        #expect(safe[3][try #require(header.firstIndex(of: "expression"))] == "'=1+1")
        #expect(!compatible.preview.hasPrefix("\u{FEFF}"))
    }

    @Test func optionsOmitFieldsAndExpressionListKeepsLiteralText() throws {
        let (entries, _) = try fixture()
        var options = VocabularyExportConfiguration()
        options.format = .text; options.textStyle = .expressions; options.images = true
        let list = try VocabularyExportPolicy.package(entries, configuration: options)
        #expect(String(decoding: list.data, as: UTF8.self) == "bank\n=1+1\n")
        #expect(list.filename.hasSuffix(".txt")); #expect(list.exampleCount == 0)
        options.format = .csv; options.examples = false; options.meanings = false; options.notes = false; options.content = false
        let rows = decodeCSV(String(decoding: try VocabularyExportPolicy.package(entries, configuration: options).data.dropFirst(3), as: UTF8.self))
        #expect(rows.count == 4)
        #expect(rows[0] == ["entry_id", "expression", "dictionary_form", "language", "type", "sense_id", "saved_at"])
    }

    @Test func variantsExcludeThePrimaryPairAndKeepDistinctLanguagesAndWordings() throws {
        var (entries, _) = try fixture()
        let primary = VocabularyMeaning(text: "银行", language: .chinese)
        let other = VocabularyMeaning(text: "Financial institution", language: .english)
        entries[0].senses[0].standaloneMeanings = [primary, other]
        entries[0].senses[0].alternateMeanings = [other, primary]
        var usage = entries[0].senses[0].examples[0]
        let translation = VocabularyMeaning(text: usage.translation, language: usage.translationLanguage)
        usage.translationVariants = [translation, .init(text: "The bank greeted us.", language: .english), translation]
        entries[0].senses[0].examples[0] = usage
        let document = VocabularyExportPolicy.document(entries, configuration: .init())
        #expect(document.entries[0].senses[0].otherMeanings == [other])
        #expect(document.entries[0].senses[0].examples?[0].otherTranslations.count == 1)
        let text = String(decoding: try VocabularyExportPolicy.package(entries, configuration: .init()).data, as: UTF8.self)
        #expect(text.contains("[zh-Hans] 银行"))
        #expect(text.contains("[zh-Hans] 银行打了招呼。"))
        #expect(text.contains("[zh-Hans] 金融机构"))
    }

    @Test func disablingExamplesDoesNotDuplicateRowsAndDictionaryFormIsPortable() throws {
        var (entries, _) = try fixture()
        entries[0].dictionaryForm = "a bank"
        var second = entries[0].senses[0].examples[0]; second.text = "Another example."
        entries[0].senses[0].examples.append(second)
        var options = VocabularyExportConfiguration(); options.format = .csv; options.examples = false
        let rows = decodeCSV(String(decoding: try VocabularyExportPolicy.package(entries, configuration: options).data.dropFirst(3),
            as: UTF8.self))
        #expect(rows.count == 4)
        #expect(rows[1][try #require(rows[0].firstIndex(of: "dictionary_form"))] == "a bank")
        options.format = .text
        #expect(String(decoding: try VocabularyExportPolicy.package(entries, configuration: options).data, as: UTF8.self)
            .contains("a bank"))
    }

    @Test func portableJSONPreservesHierarchyAndExcludesHostAndReviewMetadata() throws {
        let (entries, _) = try fixture()
        var options = VocabularyExportConfiguration(); options.format = .json
        let package = try VocabularyExportPolicy.package(entries, configuration: options)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(VocabularyExportDocument.self, from: package.data)
        #expect(doc.version == 1)
        #expect(doc.entries[0].senses.map(\.id) == entries[0].senses.map(\.id))
        #expect(doc.entries[0].senses[0].examples?.first?.meaning == "金融机构")
        #expect(doc.entries[0].senses[0].content?.first?.text?.bold == true)
        #expect(!String(decoding: package.data, as: UTF8.self).contains("private.host.identifier"))
        options.meanings = false; options.examples = false; options.notes = false; options.content = false
        let object = try JSONSerialization.jsonObject(with: VocabularyExportPolicy.package(entries, configuration: options).data)
        let top = try #require(object as? [String: Any])
        let result = try #require(top["entries"] as? [[String: Any]])
        let senses = try #require(result[0]["senses"] as? [[String: Any]])
        #expect(senses[0]["meaning"] == nil); #expect(senses[0]["content"] == nil); #expect(senses[0]["examples"] == nil)
    }

    @Test func savedExplanationsAreOptInAndExcludeModelMetadata() throws {
        var (entries, _) = try fixture()
        let capture = VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            example: entries[0].senses[0].examples[0])
        entries[0].senses[0].examples[0].explanations = [.init(id: UUID(), input: LearningExplanationPolicy.input(capture),
            language: .chinese, result: .init(meaning: "金融机构", explanation: "语境详解"),
            model: "private-model-name", createdAt: Date())]
        var options = VocabularyExportConfiguration(); options.format = .json
        let omitted = try VocabularyExportPolicy.package(entries, configuration: options)
        #expect(!String(decoding: omitted.data, as: UTF8.self).contains("语境详解"))
        options.explanation = true
        let included = String(decoding: try VocabularyExportPolicy.package(entries, configuration: options).data, as: UTF8.self)
        #expect(included.contains("语境详解")); #expect(!included.contains("private-model-name"))
    }

    @Test func cancellationLeavesAnExistingDestinationUntouched() async throws {
        let (entries, _) = try fixture(), archive = VocabularyArchive(url: nil)
        let package = try VocabularyExportPolicy.package(entries, configuration: .init())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.txt"), original = Data("Keep this file".utf8)
        try original.write(to: destination)
        let operation = Task { try await archive.writeExport(package, to: destination) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.txt"])
    }

    @Test func capturedZIPSurvivesSourceRemovalAndContainsEachImageOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = VocabularyArchive(url: directory.appendingPathComponent("notebook.sqlite"))
        let (entries, image) = try fixture()
        _ = try await archive.commitWithImages(.init(entries: entries), supplied: [image.reference.filename: image.data])
        var options = VocabularyExportConfiguration(); options.images = true
        let package = try await archive.prepareExport(selections: selections(entries), configuration: options)
        #expect(package.images.count == 1)
        _ = try await archive.remove(id: entries[0].id)
        let file = directory.appendingPathComponent("export.zip")
        try await archive.writeExport(package, to: file)
        let listing = try unzip(["-Z1", file.path])
        #expect(String(decoding: listing, as: UTF8.self).split(separator: "\n").count == 2)
        #expect(try unzip(["-p", file.path, "images/" + image.reference.filename]) == image.data)
        let text = String(decoding: try unzip(["-p", file.path, "Lingrove-vocabulary.txt"]), as: UTF8.self)
        #expect(text.contains("images/" + image.reference.filename)); #expect(text.contains("银行"))
        _ = try unzip(["-t", file.path])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func missingMediaCanBeExcludedAndExportCannotOverwriteTheNotebook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite"), archive = VocabularyArchive(url: url)
        let (entries, image) = try fixture()
        _ = try await archive.commitWithImages(.init(entries: entries), supplied: [image.reference.filename: image.data])
        let original = try Data(contentsOf: url)
        let media = url.appendingPathExtension("media").appendingPathComponent(image.reference.filename)
        try FileManager.default.removeItem(at: media)
        var options = VocabularyExportConfiguration(); options.images = true
        await #expect(throws: VocabularyExportError.self) {
            _ = try await archive.prepareExport(selections: selections(entries), configuration: options)
        }
        options.images = false
        let package = try await archive.prepareExport(selections: selections(entries), configuration: options)
        await #expect(throws: VocabularyError.self) { try await archive.writeExport(package, to: url) }
        #expect(try Data(contentsOf: url) == original)
        var bad = package; bad.images = ["../escape.png": Data([1])]
        #expect(throws: VocabularyExportError.self) { _ = try VocabularyExportZIP.data(bad) }
    }

    @Test func stalePreparedScopeCannotBeSavedAndClosedSessionCannotPublish() async throws {
        let (entries, image) = try fixture()
        let archive = VocabularyArchive(url: nil)
        _ = try await archive.commitWithImages(.init(entries: entries), supplied: [image.reference.filename: image.data])
        let store = VocabularyStore(archive: archive); await store.load()
        let all = selections(entries)
        let session = VocabularyExportSession(store: store,
            request: .init(all: all, filtered: [all[0]], selected: [all[1]], initialScope: .all))
        await session.prepare(); #expect(session.canExport)
        let previous = try #require(session.package)
        session.scope = .selected; #expect(!session.canExport)
        await session.prepare(); #expect(session.package?.senseCount == 1)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        #expect(await session.save(previous, to: destination) == false)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        session.cancel(); await session.prepare()
        #expect(session.package == nil); #expect(!session.canExport)
    }

    private func unzip(_ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return bytes
    }

    /// A receiver-side CSV state machine verifies round trips independently of the encoder.
    private func decodeCSV(_ source: String) -> [[String]] {
        let chars = Array(source); var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted, index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 } else { quoted.toggle() }
            } else if char == ",", !quoted { row.append(field); field = "" } else if char == "\r\n" || char == "\n", !quoted {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(char) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
