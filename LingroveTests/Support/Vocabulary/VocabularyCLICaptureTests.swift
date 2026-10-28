import Foundation
import Testing
@testable import Lingrove

/// These exercise the same task interface as agents. Failure cases verify that reference,
/// ambiguity and bounded-input rules reject a whole plan before the archive commits anything.
struct VocabularyCLICaptureTests {
    private func plan(_ material: String) throws -> VocabularyCLIPlan {
        let data = Data(material.utf8)
        let batch = try CLICaptureContract.decode(data)
        return try .init(batch: batch, snapshot: .init(revision: 0, document: .init()),
            fingerprint: VocabularyCLIPlan.fingerprint(batch), prepared: [:], now: Date(timeIntervalSince1970: 1_000))
    }

    @Test func explicitUncertaintyStaysProposedAndExcludedFromActiveGraph() throws {
        let result = try plan(#"""
        {"version":1,"idempotencyKey":"proposed","defaults":{"language":"en","status":"proposed"},
         "meanings":[{"ref":"delay","title":"推迟","cues":["晚点"]}],
         "entries":[{"expression":"defer","senses":[{"meaning":"推迟",
           "associations":[{"meaning":"delay","usage":"defer + noun"}]}]}]}
        """#)
        let doc = result.document
        #expect(doc.semantics.nodes[0].provenance.status == .proposed)
        #expect(doc.semantics.mappings[0].provenance.status == .proposed)
        #expect(doc.semantics.patterns[0].provenance.status == .proposed)
        #expect(VocabularyMeaningBrowserProjection.unclassified(index: doc.semantics, entries: doc.collectedEntries).count == 1)
        #expect(VocabularyMeaningBrowserProjection.items(index: doc.semantics, entries: doc.collectedEntries, query: "晚点").isEmpty)
    }

    @Test(arguments: [
        #"{"defaults":{"langauge":"en"},"entries":[]}"#,
        #"{"defaults":{"language":"en"},"entries":[{"expression":"bank","senses":[]}]}"#,
        #"{"defaults":{"language":"en"},"entries":[{"expression":"bank","senses":[{"meaning":"银行","associations":[{"meaning":"missing"}]}]}]}"#,
        #"{"defaults":{"language":"en"},"meanings":[{"ref":"x","title":"A"},{"ref":"x","title":"B"}],"entries":[{"expression":"bank","senses":[{"meaning":"银行"}]}]}"#,
        #"{"defaults":{"language":"en"},"entries":[{"expression":"bank","senses":[{"meaning":"银行","examples":[{"text":"bank bank"}]}]}]}"#,
        #"{"defaults":{"language":"en"},"meanings":[{"ref":"x","title":"A"}],"relations":[{"from":"x","to":"x","kind":"narrower"}],"entries":[{"expression":"bank","senses":[{"meaning":"银行"}]}]}"#
    ])
    func malformedTasksFailAtomically(_ body: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        object["version"] = 1; object["idempotencyKey"] = "invalid"
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            let result = try plan(String(decoding: bytes, as: UTF8.self))
            try VocabularyLifecyclePolicy.validate(result.document)
            try VocabularySemanticPolicy.validate(result.document.semantics, entries: result.document.entries)
        }
    }
}
