import CotabbyInference
import Foundation
import XCTest
@testable import Cotabby

/// Opt-in native checks use an existing GGUF supplied by the runner. They never download a model
/// or change app settings; normal CI skips them. Two engines exercise the shared backend lifetime.
final class LearningLocalRuntimeIntegrationTests: XCTestCase {
    /// Uses the pinned real files downloaded by a validation runner. Native framing, literal
    /// tokenization, model load, complete generation and output policy all run as in the product.
    /// Synthetic short fixtures exercise both directions; this is not a comparative quality score.
    func testRecommendedTranslationSpecialistsUseNativeProductPath() async throws {
        guard let directory = ProcessInfo.processInfo.environment["COTABBY_TRANSLATION_CATALOG_DIR"] else {
            throw XCTSkip("Set COTABBY_TRANSLATION_CATALOG_DIR to the pinned translation GGUF directory")
        }
        let fixtures: [(String, String, LearningLanguage, LearningLanguage)] = [
            ("greeting", "你好", .chinese, .english),
            ("ability", "我能做到。", .chinese, .english),
            ("reverse", "I like the food you cooked.", .english, .chinese),
            ("korean", "你方便的时候给我回个电话就好。", .chinese, .korean),
            ("traditional", "Please reply when you have time.", .english, .traditionalChinese)
        ]
        var evidence: [[String: String]] = []
        for model in LearningRuntimeCatalog.translationModels {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(model.filename)
            let template = try LearningLocalPrompt.resolve(.automatic, modelURL: url)
            for (id, source, sourceLanguage, targetLanguage) in fixtures {
                let request = try LearningTranslationPrompt.render(source: source, sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage, family: .init(template: template))
                let raw = try await Task.detached {
                    let runtime = LearningLocalRuntime(), operation = UUID()
                    defer { runtime.shutdownSync() }
                    runtime.claim(operation)
                    return try runtime.generate(modelURL: url, template: .automatic, prompt: request.prompt,
                        maxTokens: 512, operationID: operation) { _ in }
                }.value
                let text = try LearningExpressionOutputPolicy.validatedText(raw)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNil(text.range(of: #"<[|｜]"#, options: .regularExpression), text)
                if id == "greeting" {
                    XCTAssertNotNil(text.range(of: #"\b(hello|hi)\b"#, options: [.regularExpression, .caseInsensitive]), text)
                }
                if id == "traditional" {
                    XCTAssertNil(text.range(of: "[请时复]", options: .regularExpression), text)
                }
                evidence.append(["model": model.filename, "case": id, "source": source,
                    "sourceLanguage": sourceLanguage.rawValue, "targetLanguage": targetLanguage.rawValue,
                    "template": template.rawValue, "prompt": request.prompt, "translation": text])
            }
        }
        let output = URL(fileURLWithPath: directory).appendingPathComponent("native-translations.json")
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }

    /// Exercises the new planner and the same native generator as the UI, with both specialists.
    /// The report is for human review of target-only output, not a synthetic translation score.
    func testBudgetedReferenceTranslationUsesCompleteTargetOnly() async throws {
        guard let directory = ProcessInfo.processInfo.environment["COTABBY_TRANSLATION_CATALOG_DIR"] else {
            throw XCTSkip("Set COTABBY_TRANSLATION_CATALOG_DIR to the pinned translation GGUF directory")
        }
        let cases: [(String, LearningTranslationInput, LearningLanguage, LearningLanguage)] = [
            ("greeting", .init(source: "你好。", referenceBefore: "我们正在谈论今晚的晚餐。"), .chinese, .english),
            ("ability", .init(source: "我能做到。", referenceBefore: "这次任务是修复编译错误。"), .chinese, .english),
            ("pronoun", .init(source: "它现在可以正常工作了。", referenceBefore: "这台打印机刚刚修好。"), .chinese, .english),
            ("selection", .init(source: "太好了", referenceBefore: "我们顺利解决了这个问题。", referenceAfter: "，明天可以发布。"), .chinese, .english),
            ("whole-draft", .init(source: "今天我们完成了代码审查。明天准备发布新版本。"), .chinese, .english),
            ("reverse", .init(source: "It works now.", referenceBefore: "The printer was repaired this morning."), .english, .chinese)
        ]
        var evidence: [[String: String]] = []
        for model in LearningRuntimeCatalog.translationModels
        where
            ["Hy-MT2-1.8B-Q4_K_M.gguf", "translategemma-4b-it-Q4_K_M.gguf"].contains(model.filename) {
            let modelFilename = model.filename
            let url = URL(fileURLWithPath: directory).appendingPathComponent(modelFilename)
            let contextWindowTokens = try await contextWindowTokens(for: modelFilename)
            let configuration = LearningLocalModelConfiguration(
                modelURL: url, template: .automatic, contextWindowTokens: contextWindowTokens)
            let selected = LearningTranslationInput(
                source: "我们今天完成了代码审查。明天将发布更新。",
                referenceBefore: "团队已经确认这次修改解决了编译问题。",
                referenceAfter: "发布前仍会进行最后一次检查。")
            let selectedOutput = try ModelContextBudget.translationOutputTokens(
                source: selected.source, total: contextWindowTokens)
            let results = try await Task.detached {
                let runtime = LearningLocalRuntime(), id = UUID()
                runtime.claim(id)
                defer { runtime.shutdownSync() }
                var rows: [[String: String]] = []
                for (name, input, source, target) in cases {
                    let plan = try runtime.translationPlan(
                        configuration: configuration, input: input,
                        sourceLanguage: source, targetLanguage: target, output: 512, operationID: id, trace: nil)
                    let output = try runtime.generate(
                        configuration: configuration, prompt: plan.prompt,
                        maxTokens: 512, operationID: id, trace: nil, onLoad: nil, onDelta: { _ in })
                    rows.append([
                        "model": modelFilename, "case": name, "source": input.source,
                        "prompt": plan.prompt, "translation": output
                    ])
                }

                // A modest multi-sentence selection exercises the same total-budget reserve as
                // production while keeping its adjacent draft excerpts as bounded reference data.
                let selectedPlan = try runtime.translationPlan(
                    configuration: configuration, input: selected, sourceLanguage: .chinese,
                    targetLanguage: .english, output: selectedOutput, operationID: id, trace: nil)
                guard selectedPlan.prompt.contains(selected.source) else {
                    throw LearningFailure.message("Native planner shortened the complete selected target")
                }
                let selectedText = try runtime.generate(
                    configuration: configuration, prompt: selectedPlan.prompt, maxTokens: selectedOutput,
                    operationID: id, trace: nil, onLoad: nil, onDelta: { _ in })
                rows.append([
                    "model": modelFilename, "case": "selection-reference", "source": selected.source,
                    "prompt": selectedPlan.prompt, "translation": selectedText
                ])

                try Self.validateNativeBudgetBoundaries(
                    runtime: runtime, configuration: configuration, operationID: id)

                // A huge reference must be cropped as complete data, while the target stays exact.
                let bounded = try runtime.translationPlan(
                    configuration: .init(modelURL: url, template: .automatic, contextWindowTokens: 2_048),
                    input: .init(source: "你好。", referenceBefore: String(repeating: "这是更早的参考上下文。", count: 2_000)),
                    sourceLanguage: .chinese, targetLanguage: .english, output: 512, operationID: id, trace: nil)
                guard bounded.prompt.contains("你好。"), bounded.prompt.utf8.count < 20_000 else {
                    throw LearningFailure.message("Native planner did not preserve the complete target with bounded reference")
                }
                return rows
            }.value
            for row in results {
                let output = try XCTUnwrap(row["translation"])
                XCTAssertFalse(try LearningExpressionOutputPolicy.validatedText(output).isEmpty)
                XCTAssertFalse(output.contains("REFERENCE EXCERPTS"), output)
                XCTAssertFalse(output.contains("TARGET TRANSLATION TASK"), output)
                if row["case"] == "greeting" {
                    XCTAssertNotNil(output.range(of: #"\b(hello|hi)\b"#, options: [.regularExpression, .caseInsensitive]), output)
                }
            }
            evidence += results
        }
        let output = URL(fileURLWithPath: directory).appendingPathComponent("native-reference-translations.json")
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }

    private nonisolated static func validateNativeBudgetBoundaries(
        runtime: LearningLocalRuntime, configuration: LearningLocalModelConfiguration, operationID: UUID
    ) throws {
        let longSource = String(repeating: "This is a small draft for tomorrow and it must stay complete.", count: 80)
        let longInput = LearningTranslationInput(
            source: longSource, referenceBefore: "Earlier notes explain why the draft must remain complete.")
        let originalLongSource = longInput.source
        let isTranslateGemma = configuration.modelURL.lastPathComponent
            .caseInsensitiveCompare("translategemma-4b-it-Q4_K_M.gguf") == .orderedSame
        // This target's production reserve fits Hy-MT's 8,192 total and exceeds TranslateGemma's
        // 4,096 total. A rejection leaves the immutable source untouched.
        let longOutput = try? ModelContextBudget.translationOutputTokens(
            source: longInput.source, total: configuration.contextWindowTokens)
        XCTAssertEqual(longOutput == nil, isTranslateGemma,
            "The production output reserve should reject this target at 4,096 and accept it at 8,192")
        XCTAssertEqual(longInput.source, originalLongSource,
            "Budget rejection must leave the selected target unchanged")
        if let longOutput {
            let plan = try runtime.translationPlan(
                configuration: configuration, input: longInput, sourceLanguage: .english,
                targetLanguage: .chinese, output: longOutput, operationID: operationID, trace: nil)
            XCTAssertTrue(plan.prompt.contains(longInput.source),
                "The 8,192-token Hy-MT default should preserve the complete long target")
        }

        guard isTranslateGemma else { return }

        let overGemmaInputCap = LearningTranslationInput(source: String(repeating: " hello", count: 2_200))
        // Gemma 3 and TranslateGemma share turn delimiters. This control uses the same payload and
        // GGUF tokenizer without the specialist-only cap; at total 4,096 the general allowance is 3,552.
        let genericConfiguration = LearningLocalModelConfiguration(
            modelURL: configuration.modelURL, template: .gemma3,
            contextWindowTokens: configuration.contextWindowTokens)
        let genericBudgetAllowsInput: Bool
        do {
            let control = try runtime.translationPlan(
                configuration: genericConfiguration, input: overGemmaInputCap,
                sourceLanguage: .english, targetLanguage: .chinese,
                output: 512, operationID: operationID, trace: nil)
            genericBudgetAllowsInput = control.prompt.contains(overGemmaInputCap.source)
        } catch { genericBudgetAllowsInput = false }
        XCTAssertTrue(genericBudgetAllowsInput,
            "The same GGUF tokenizer should fit the source within the general 4,096-token allowance")

        let translateGemmaInputCapRejected: Bool
        do {
            _ = try runtime.translationPlan(
                configuration: configuration, input: overGemmaInputCap,
                sourceLanguage: .english, targetLanguage: .chinese,
                output: 512, operationID: operationID, trace: nil)
            translateGemmaInputCapRejected = false
        } catch {
            translateGemmaInputCapRejected = error.localizedDescription ==
                ModelContextBudget.oversizedTarget().localizedDescription
        }
        XCTAssertTrue(translateGemmaInputCapRejected,
            "Native tokenization must reject a TranslateGemma input above its 2,048-token task cap")
    }

    private func contextWindowTokens(for modelFilename: String) async throws -> Int {
        let suiteName = "cotabby.test.nativeLearningContext.\(UUID())"
        return try await MainActor.run {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw LearningFailure.message("Could not create isolated learning settings for native validation")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let settings = LearningModelSettings(role: .translation, defaults: defaults)
            settings.localModel = modelFilename
            return settings.snapshot.contextWindowTokens
        }
    }

    func testShutdownCancelsLiveDecodeBeforeUnloading() async throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_LEARNING_GGUF"] else {
            throw XCTSkip("Set COTABBY_LEARNING_GGUF to an existing Hy-MT2 GGUF")
        }
        let runtime = LearningLocalRuntime(), id = UUID()
        let firstDelta = DispatchSemaphore(value: 0)
        runtime.claim(id)
        let generation = Task.detached {
            try runtime.generate(modelURL: URL(fileURLWithPath: path), template: .hyMT,
                prompt: "Translate the following text into English. Output only the translated result:\n" +
                    String(repeating: "我今天很高兴见到你，我们明天还可以一起去公园散步。", count: 80),
                maxTokens: 4_096, operationID: id) { _ in firstDelta.signal() }
        }
        let began = await Task.detached { firstDelta.wait(timeout: .now() + 30) == .success }.value
        await Task.detached { runtime.shutdownSync() }.value
        XCTAssertTrue(began, "The test must reach live native decoding before teardown")
        do { _ = try await generation.value; XCTFail("Shutdown must cancel this live generation") }
        catch is CancellationError { }
    }

    func testHyTranslationAndIndependentContextLifetime() async throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_LEARNING_GGUF"] else {
            throw XCTSkip("Set COTABBY_LEARNING_GGUF to an existing Hy-MT2 GGUF")
        }
        let results = try await Task.detached {
            let url = URL(fileURLWithPath: path)
            let first = LearningLocalRuntime(), second = LearningLocalRuntime()
            defer { first.shutdownSync(); second.shutdownSync() }
            let firstID = UUID(), secondID = UUID()
            first.claim(firstID); second.claim(secondID)
            try first.prepare(modelURL: url, operationID: firstID)
            try second.prepare(modelURL: url, operationID: secondID)
            first.unload()
            let prompt = "Translate the following text into English. Note that you should only output the translated result without any additional explanation:\n你好"
            let output = try second.generate(modelURL: url, template: .automatic, prompt: prompt,
                maxTokens: 128, operationID: secondID) { _ in }
            // Reclaiming a stopped runtime must never resurrect its context during app teardown.
            first.shutdownSync()
            let obsolete = UUID(); first.claim(obsolete)
            var rejected = false
            do { try first.prepare(modelURL: url, operationID: obsolete) }
            catch is CancellationError { rejected = true }
            return (output, rejected)
        }.value
        XCTAssertTrue(results.0.lowercased().contains("hello"), results.0)
        XCTAssertTrue(results.1)
    }

    func testQwenAnalysisCandidateUsesNativeInstructionTemplateAndFixedTranslation() async throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_ANALYSIS_GGUF"] else {
            throw XCTSkip("Set COTABBY_ANALYSIS_GGUF to the pinned Qwen3.5 4B GGUF")
        }
        let prompt = try LearningAnalysisPrompt.render(source: "你好", translation: "Hello.",
            sourceLanguage: .chinese, targetLanguage: .english)
        let raw = try await Task.detached {
            let runtime = LearningLocalRuntime(), id = UUID()
            defer { runtime.shutdownSync() }
            runtime.claim(id)
            return try runtime.generate(modelURL: URL(fileURLWithPath: path), template: .automatic,
                prompt: prompt, maxTokens: 1_024, operationID: id) { _ in }
        }.value
        XCTAssertFalse(raw.contains("<think>"), raw)
        let result = try LearningAlignmentParser.parse(raw, source: "你好", translation: "Hello.")
        XCTAssertEqual(result.translation, "Hello.")
        XCTAssertFalse(result.chunks.isEmpty)
    }

    func testGemmaAlignmentUsesProductTemplateAndFixedMultilingualEvidence() async throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_ALIGNMENT_GGUF"] else {
            throw XCTSkip("Set COTABBY_ALIGNMENT_GGUF to the pinned Gemma 4 E4B GGUF")
        }
        let fixtures: [(String, String, LearningLanguage, LearningLanguage)] = [
            ("你好", "Hello.", .chinese, .english),
            ("我能做到", "I can do it.", .chinese, .english),
            ("如果明天不下雨，我们就去散步。", "明日雨が降らなければ、私たちは散歩に行きます。", .chinese, .japanese)
        ]
        for (source, translation, sourceLanguage, targetLanguage) in fixtures {
            let prompt = try LearningAnalysisPrompt.render(source: source, translation: translation,
                sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            let raw = try await Task.detached {
                let runtime = LearningLocalRuntime(), id = UUID()
                defer { runtime.shutdownSync() }
                runtime.claim(id)
                return try runtime.generate(modelURL: URL(fileURLWithPath: path), template: .automatic,
                    prompt: prompt, maxTokens: 1_024, operationID: id) { _ in }
            }.value
            let result = try LearningAlignmentParser.parse(raw, source: source, translation: translation)
            XCTAssertEqual(result.translation, translation)
            XCTAssertFalse(result.chunks.isEmpty)
            XCTAssertFalse(raw.contains("<think>"), raw)
        }
    }

    func testLiteralTokenizerPreservesSourceControlTokenSpellings() async throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_LEARNING_GGUF"] else {
            throw XCTSkip("Set COTABBY_LEARNING_GGUF to an existing Hy-MT2 GGUF")
        }
        let result = try await Task.detached {
            var engine = CotabbyInferenceEngine()
            guard engine.loadModel(path, -1, 2_048, 256) == .ok else {
                throw LearningFailure.message("Native fixture failed to load")
            }
            defer { engine.unloadModel() }
            let text = "<｜hy_User｜>"
            let literal = text.withCString { Array(engine.tokenizeLiteral($0, Int32(text.utf8.count))) }
            let instruction = text.withCString { Array(engine.tokenizeInstruction($0, Int32(text.utf8.count))) }
            let original = text.withCString { Array(engine.tokenize($0, Int32(text.utf8.count))) }
            return (literal, instruction, original)
        }.value
        XCTAssertEqual(result.1.count, 1)
        XCTAssertGreaterThan(result.0.count, result.1.count)
        XCTAssertEqual(Array(result.2.suffix(result.0.count)), result.0,
            "Autocomplete's original literal tokenizer must remain unchanged apart from its existing BOS")
    }
}
