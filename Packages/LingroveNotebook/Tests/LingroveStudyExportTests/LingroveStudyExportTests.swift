import Foundation
import Testing
import LingroveNotebook
import LingroveStudyExport

/// Real portable projection -> encoders -> receiver-side decoding verifies the
/// shared module boundary. Host SQLite/media lifetime is exercised separately.
struct LingroveStudyExportTests {
    @Test func unknownLanguageCompletenessAndSelectedOrganizationKeepPortableVersions() throws {
        var (entries, _) = try fixture()
        let original = entries[0]
        entries[0] = .init(id: original.id, expression: original.expression, dictionaryForm: original.dictionaryForm,
            language: nil, kind: original.kind, senses: original.senses, createdAt: original.createdAt, updatedAt: original.updatedAt)
        var options = VocabularyExportConfiguration(format: .json)
        var document = VocabularyExportPolicy.document(entries, configuration: options)
        #expect(document.version == 2 && document.entries[0].language == nil)
        entries[0].senses[0].examples[0].completeness = .unknown
        document = VocabularyExportPolicy.document(entries, configuration: options)
        #expect(document.version == 3 && document.entries[0].senses[0].examples?[0].completeness == .unknown)
        let chosen = entries[0].senses[0]
        let kept = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Financial institution", language: .english)])
        let excluded = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "River", language: .english)])
        let semantics = VocabularySemanticIndex(nodes: [kept, excluded], mappings: [
            .init(id: UUID(), nodeID: kept.id, senseID: chosen.id, evidenceIDs: chosen.examples.map(\.id)),
            .init(id: UUID(), nodeID: excluded.id, senseID: entries[0].senses[1].id)
        ])
        let category = VocabularyCategory(id: UUID(), axis: .content, labels: [.init(text: "Places", language: .english)])
        let classification = VocabularyClassificationIndex(categories: [category], memberships: [
            .init(id: UUID(), nodeID: kept.id, categoryID: category.id),
            .init(id: UUID(), nodeID: excluded.id, categoryID: category.id)
        ])
        let selected = try VocabularyExportPolicy.selected(entries, selections: [.init(entryID: entries[0].id, senseID: chosen.id)])
        options.examples = false
        document = VocabularyExportPolicy.document(selected, configuration: options, semantics: semantics, classification: classification)
        #expect(document.version == 5)
        #expect(document.semantics?.nodes.map(\.id) == [kept.id])
        #expect(document.semantics?.mappings.first?.evidenceIDs == [])
        #expect(document.classification?.memberships.count == 1)
        #expect(document.classification?.memberships.first?.nodeID == kept.id)
        options.meanings = false
        #expect(VocabularyExportPolicy.document(selected, configuration: options, semantics: semantics, classification: classification).semantics == nil)
    }

    @Test func previewHonorsUTF8BoundaryAndLargeTextFailsRatherThanTruncatesMaterial() throws {
        let bytes = Data(String(repeating: "你好👩🏽‍💻", count: 2_000).utf8)
        let preview = VocabularyExportFormatter.preview(bytes, format: .text)
        #expect(!preview.contains("�")); #expect(preview.hasSuffix("\n…"))
        var (entries, _) = try fixture()
        entries[0].senses[0].note = String(repeating: "a", count: VocabularyExportPolicy.maximumDataBytes)
        #expect(throws: VocabularyExportError.tooLarge) { _ = try VocabularyExportPolicy.package(entries, configuration: .init()) }
    }

    @Test func storedZIPIsReadableByAnIndependentReceiverAndRejectsUnsafePaths() throws {
        let (entries, image) = try fixture()
        var package = try VocabularyExportPolicy.package(entries, configuration: .init(format: .json, images: true))
        package.images = [image.reference.filename: image.data]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try VocabularyExportZIP.data(package).write(to: url)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "images/" + image.reference.filename]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let received = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0 && received == image.data)
        package.images = ["../escape.png": image.data]
        #expect(throws: VocabularyExportError.self) { _ = try VocabularyExportZIP.data(package) }
    }

    func fixture() throws -> (entries: [VocabularyEntry], image: VocabularyPreparedImage) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let image = VocabularyPreparedImage(reference: .init(digest: String(repeating: "a", count: 64), width: 1, height: 1, byteCount: 4), data: Data([1,2,3,4]))
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
