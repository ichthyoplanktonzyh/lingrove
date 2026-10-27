import CotabbyInference
import Foundation
import Testing
@testable import Lingrove

/// Opt-in native fixtures check syntax and sampler ownership, never the truth of a definition.
/// One borrowed GGUF exercises the exact C++ bridge used by the learning runtime.
struct LearningOutputGrammarTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_GGUF"] != nil))
    func nativeGrammarAcceptsOnlyGeneratedTextAndDoesNotLeakIntoOrdinarySampling() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_GGUF"])
        let evidence = try await Task.detached {
            var engine = CotabbyInferenceEngine()
            guard engine.loadModel(path, -1, 2_048, 256) == .ok else { throw VocabularyError.invalidContent }
            defer { engine.unloadModel() }
            let config = SamplingConfig(temperature: 0.3, top_k: 40, top_p: 0.9, min_p: 0,
                repetition_penalty: 1, seed: 42, single_line: false)
            // These are instruction GGUFs. Use their real turn framing so an immediate EOS on
            // an unframed string cannot make the ordinary-sampling comparison vacuous.
            let template = try LearningLocalPrompt.resolve(.automatic, modelURL: URL(fileURLWithPath: path))
            let prompt = try LearningLocalPrompt.render("Write a short greeting in English.", template: template)
            let before = try Self.generate(&engine, config: config, prompt: prompt, grammar: nil)

            let expected = #"{"meaning":"你好 \"Hello\" 😀","explanation":"C:\\tmp\n下一行"}"#
            let literal = try #require(String(data: JSONEncoder().encode(expected), encoding: .utf8))
            let quoted = try Self.generate(&engine, config: config, prompt: prompt, grammar: "root ::= " + literal)
            let invalid = "root ::= [".withCString { engine.createSequenceWithGrammar(config, $0) }
            let after = try Self.generate(&engine, config: config, prompt: prompt, grammar: nil)

            var structured: [String] = []
            for grammar in [LearningOutputGrammar.lookup(hasContext: true),
                            LearningOutputGrammar.lookup(hasContext: false), LearningOutputGrammar.explanation] {
                let output = try Self.generate(&engine, config: config,
                    prompt: LearningLocalPrompt.render(
                        "Return a short JSON object with meaning, then sentence_translation or explanation.", template: template),
                    grammar: grammar)
                structured.append(output.text)
            }
            return (before.tokens, after.tokens, quoted.text, expected, invalid, structured)
        }.value
        #expect(!evidence.0.isEmpty, "The ordinary-sampling comparison must include generated tokens")
        #expect(evidence.0 == evidence.1, "An intervening grammar must not change ordinary seeded sampling")
        #expect(evidence.2 == evidence.3, "Quotes, backslashes, Unicode and escaped newlines must survive verbatim")
        #expect(evidence.4 == -1, "An invalid grammar must fail before publishing a native sequence")
        for (index, raw) in evidence.5.enumerated() {
            let fields = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String])
            #expect(Set(fields.keys) == (index == 2 ? ["meaning", "explanation"] : ["meaning", "sentence_translation"]))
            #expect(fields["meaning"]?.isEmpty == false)
            if index == 1 { #expect(fields["sentence_translation"]?.isEmpty == true) }
        }
    }

    private nonisolated static func generate(_ engine: inout CotabbyInferenceEngine, config: SamplingConfig,
                                             prompt: String, grammar: String?) throws -> (text: String, tokens: [Int32]) {
        let sequence = grammar.map { text in text.withCString { engine.createSequenceWithGrammar(config, $0) } }
            ?? engine.createSequence(config)
        guard sequence >= 0 else { throw VocabularyError.invalidContent }
        defer { engine.destroySequence(sequence) }
        // All text here is a trusted synthetic fixture, including the model's role markers.
        var promptTokens = Array(prompt.withCString { engine.tokenizeInstruction($0, Int32(prompt.utf8.count)) })
        guard engine.decodePrompt(sequence, &promptTokens, Int32(promptTokens.count), 0) == .ok else {
            throw VocabularyError.invalidContent
        }
        var bytes: [UInt8] = [], tokens: [Int32] = []
        for _ in 0..<256 {
            let sample = engine.sampleNext(sequence)
            guard !sample.was_cancelled else { throw CancellationError() }
            if sample.is_eos {
                guard let text = String(bytes: bytes, encoding: .utf8) else { throw VocabularyError.invalidContent }
                return (text, tokens)
            }
            guard let piece = sample.piece else { throw VocabularyError.invalidContent }
            // The engine lends this buffer until the next sample; copy its exact bytes now so
            // split UTF-8 tokens can be reassembled before decoding the complete output.
            bytes += UnsafeBufferPointer(start: UnsafeRawPointer(piece).assumingMemoryBound(to: UInt8.self),
                count: Int(sample.piece_length))
            tokens.append(sample.token)
            if grammar == nil, tokens.count == 16 { return (String(bytes: bytes, encoding: .utf8) ?? "", tokens) }
        }
        throw VocabularyError.invalidContent
    }
}
