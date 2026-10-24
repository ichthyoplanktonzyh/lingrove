import Foundation
import XCTest
@testable import Lingrove

/// Opt-in evidence runs the real planner and native sampler with identical source, seed and
/// model files. It records phrasing for human review; it does not pretend to grade style quality.
final class LearningTranslationStyleIntegrationTests: XCTestCase {
    func testTranslationStylesWithPinnedSpecialists() async throws {
        guard let directory = LingroveCompatibility.processEnvironment["LINGROVE_TRANSLATION_CATALOG_DIR"],
              let report = LingroveCompatibility.processEnvironment["LINGROVE_STYLE_REPORT"] else {
            throw XCTSkip("Supply local model directory and report path for native style acceptance")
        }
        let root = URL(fileURLWithPath: directory)
        let rows = try await Task.detached {
            var rows: [[String: String]] = []
            for filename in ["Hy-MT2-1.8B-Q4_K_M.gguf", "translategemma-4b-it-Q4_K_M.gguf"] {
                let runtime = LearningLocalRuntime(), operation = UUID()
                runtime.claim(operation)
                let config = LearningLocalModelConfiguration(modelURL: root.appendingPathComponent(filename),
                    template: .automatic, contextWindowTokens: 4096,
                    samplingOverrides: .init(seedMode: .fixed, fixedSeed: 42))
                do {
                    for source in ["麻烦你有空的时候给我回个电话就好。", "我今天没有在3点发送2个文件。"] {
                        let registers: [LearningTranslationStyle.Register] = filename.contains("translategemma") ? [.natural] : [.natural, .formal, .conversational]
                        for register in registers {
                            let input = LearningTranslationInput(source: source, style: .init(register: register))
                            let request = try runtime.translationPlan(configuration: config, input: input,
                                sourceLanguage: .chinese, targetLanguage: .english, output: 512,
                                operationID: operation, trace: nil)
                            let raw = try runtime.generate(configuration: config, prompt: request.prompt,
                                maxTokens: 512, operationID: operation, trace: nil, onLoad: nil) { _ in }
                            let text = try LearningExpressionOutputPolicy.validatedText(raw)
                            rows.append(["model": filename, "source": source, "style": register.rawValue,
                                "translation": text, "prompt": request.prompt])
                        }
                    }
                    runtime.shutdownSync()
                } catch { runtime.shutdownSync(); throw error }
            }
            return rows
        }.value
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report))
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let text = try XCTUnwrap(row["translation"])
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("Translation style preference"), text)
            if row["source"]?.contains("2个") == true {
                XCTAssertNotNil(text.range(of: #"\b(no|not|didn['’]t|haven['’]t|hasn['’]t)\b"#, options: [.regularExpression, .caseInsensitive]), text)
                XCTAssertNotNil(text.range(of: #"\b(2|two)\b"#, options: [.regularExpression, .caseInsensitive]), text)
                XCTAssertNotNil(text.range(of: #"\b(3|three)\b"#, options: [.regularExpression, .caseInsensitive]), text)
            }
        }
    }
}
