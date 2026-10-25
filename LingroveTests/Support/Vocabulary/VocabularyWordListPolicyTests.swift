import Foundation
import Testing
@testable import Lingrove

struct VocabularyWordListPolicyTests {
    private func table(_ text: String, suffix: String = "csv") throws -> VocabularyWordList {
        try VocabularyWordListPolicy.decode(Data(text.utf8), fileExtension: suffix)
    }

    @Test func quotedCSVPreservesUnicodeCommasQuotesAndPhysicalLines() throws {
        let source = "\u{FEFF}expression,meaning,notes\r\n\"keep me posted\",\"告诉我，最新进展\",\"say \"\"hello\"\"\r\nsecond line\"\r\nbank,河岸,\r\n"
        let value = try table(source)
        let config = VocabularyWordListPolicy.configuration(for: value, language: .english)
        let inputs = try VocabularyWordListPolicy.inputs(value, configuration: config)
        #expect(config.hasHeader)
        #expect(inputs.count == 2 && inputs[0].meaning == "告诉我，最新进展")
        #expect(inputs[0].note == "say \"hello\"\r\nsecond line")
        #expect(value.rows.map(\.line) == [1, 2, 4])
    }

    @Test func headerlessAndReorderedColumnsCanBeMappedWithoutDiscardingTheFirstWord() throws {
        let value = try table("hola,a greeting\nadiós,a farewell")
        var config = VocabularyWordListPolicy.configuration(for: value, language: .spanish)
        #expect(!config.hasHeader)
        #expect(try VocabularyWordListPolicy.inputs(value, configuration: config).map(\.expression) == ["hola", "adiós"])
        config.columns = [.expression: 1, .meaning: 0]
        #expect(try VocabularyWordListPolicy.inputs(value, configuration: config)[0].expression == "a greeting")
    }

    @Test func mappedLanguagesTypesAndChineseHeadersRetainPerRowIntent() throws {
        let value = try table("单词,释义,语言,类型,释义语言,标签\nbank,河岸,en,word,zh-Hans,work; water\nkeep me posted,让我知道,en,expression,zh-Hans,work")
        let config = VocabularyWordListPolicy.configuration(for: value, language: .french)
        let inputs = try VocabularyWordListPolicy.inputs(value, configuration: config)
        #expect(inputs[0].language == .english && inputs[0].meaningLanguage == .chinese)
        #expect(inputs[0].tags == ["water", "work"])
        #expect(inputs[1].kind == .expression)
    }

    @Test func textIsOneExpressionPerLineAndUTF16BOMIsAccepted() throws {
        let text = "  hello  \r\n\r\nkeep me posted\ncomma, stays literal\n👩🏽‍💻"
        let data = try #require(text.data(using: .utf16))
        let value = try VocabularyWordListPolicy.decode(data, fileExtension: "TXT")
        let config = VocabularyWordListPolicy.configuration(for: value, language: .english)
        #expect(!config.hasHeader)
        #expect(try VocabularyWordListPolicy.inputs(value, configuration: config).map(\.expression)
            == ["hello", "keep me posted", "comma, stays literal", "👩🏽‍💻"])
        #expect(value.rows.map(\.line) == [1, 3, 4, 5])
    }

    @Test(arguments: ["expression,meaning\n\"unterminated", "word,\"closed\"oops", "un\"escaped,meaning"])
    func malformedQuotingFailsInsteadOfImportingPartialContent(_ text: String) {
        #expect(throws: VocabularyWordListError.self) { try table(text) }
    }

    @Test func invalidRowsAndMappingsExplainWhichLineNeedsCorrection() throws {
        let value = try table("expression,meaning,language\n\"two\nlines\",meaning,en\n,missing,en")
        let config = VocabularyWordListPolicy.configuration(for: value, language: .english)
        do {
            _ = try VocabularyWordListPolicy.inputs(value, configuration: config)
            Issue.record("A missing expression must block the entire list")
        } catch VocabularyWordListError.missingExpression(let line) { #expect(line == 4) }
        var invalid = config
        invalid.columns[.expression] = -1
        #expect(throws: VocabularyWordListError.self) { try VocabularyWordListPolicy.inputs(value, configuration: invalid) }
        for source in ["expression,language\nhello,unsupported", "expression,type\nhello,unknown"] {
            let table = try table(source)
            #expect(throws: VocabularyWordListError.self) {
                try VocabularyWordListPolicy.inputs(table, configuration: VocabularyWordListPolicy.configuration(for: table, language: .english))
            }
        }
    }

    @Test func resourceAndEncodingLimitsFailBeforeProducingAPreview() throws {
        #expect(throws: VocabularyWordListError.self) {
            try VocabularyWordListPolicy.decode(Data([0xFF]), fileExtension: "txt")
        }
        #expect(throws: VocabularyWordListError.self) {
            try VocabularyWordListPolicy.decode(Data(repeating: 65, count: VocabularyWordListPolicy.maximumBytes + 1), fileExtension: "txt")
        }
        #expect(throws: VocabularyWordListError.self) { try table(String(repeating: "a\n", count: 10_001), suffix: "txt") }
        #expect(throws: VocabularyWordListError.self) { try table(String(repeating: "a,", count: 64) + "a") }
        #expect(throws: VocabularyWordListError.self) { try table("word", suffix: "json") }
        #expect(throws: VocabularyWordListError.self) { try table("\n \n", suffix: "txt") }
        let formula = try table("=1+1", suffix: "txt")
        #expect(formula.rows.first?.cells == ["=1+1"])
    }
}
