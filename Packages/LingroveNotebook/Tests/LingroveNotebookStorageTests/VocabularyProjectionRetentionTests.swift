import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookPersistenceCodec

/// Retained readers may outlive many writes. These tests protect value isolation across
/// overlay compaction and exact author bytes when Swift's canonical String equality agrees.
struct VocabularyProjectionRetentionTests {
    @Test func retainedMapsSurviveCompactionRemovalAndReinsertion() {
        let initial = Dictionary(uniqueKeysWithValues: (0..<4_096).map { ($0, "old-\($0)") })
        let before = VocabularyProjectionMap(initial)
        var next = before, expected = initial
        for id in 0..<3_000 {
            if id.isMultiple(of: 3) { _ = next.removeValue(forKey: id); expected.removeValue(forKey: id) }
            else { next[id] = "new-\(id)"; expected[id] = "new-\(id)" }
        }
        let retained = next
        for id in 0..<3_000 { next[id] = "again-\(id)" }
        #expect(Dictionary(uniqueKeysWithValues: initial.keys.compactMap { key in before[key].map { (key, $0) } }) == initial)
        #expect(Dictionary(uniqueKeysWithValues: initial.keys.compactMap { key in retained[key].map { (key, $0) } }) == expected)
        #expect(next[0] == "again-0" && retained[0] == nil && before[0] == "old-0")
    }

    @Test func literalComparisonRetainsCanonicalEquivalentStringsAndSignedZero() throws {
        let id = UUID(), now = Date(timeIntervalSince1970: 10)
        let texts = ["é", "e\u{301}", "e\u{301}\u{323}", "e\u{323}\u{301}"]
        func row(_ value: String) throws -> VocabularyPersistenceRow {
            try .init(record: .init(table: .sources, id: id.uuidString, parentID: nil, position: 0,
                payload: .source(.init(id: id, text: value, kind: .authored, appBundleIdentifier: nil, encounteredAt: now))))
        }
        for pair in [(texts[0], texts[1]), (texts[2], texts[3])] {
            let before = try row(pair.0), after = try row(pair.1)
            #expect(before.record.payload == after.record.payload)
            #expect(try !before.hasSameLiteralPayload(as: after))
            #expect(try before.hasSameLiteralPayload(as: before))
        }
        var node = VocabularyMeaningNode(id: id, labels: [], provenance: .init(confidence: 0.0))
        let before = try VocabularyPersistenceRow(record: .init(table: .meaningNodes, id: id.uuidString,
            parentID: nil, position: 0, payload: .meaningNode(node), extra: [node.kind.rawValue]))
        node.provenance.confidence = -0.0
        let after = try VocabularyPersistenceRow(record: .init(table: .meaningNodes, id: id.uuidString,
            parentID: nil, position: 0, payload: .meaningNode(node), extra: [node.kind.rawValue]))
        #expect(before.record.payload == after.record.payload)
        #expect(try !before.hasSameLiteralPayload(as: after))
    }

    @Test func scopedOrganizationRowsReconstructExactlyAndKeepOlderProjection() throws {
        let now = Date(timeIntervalSince1970: 10)
        let sense = VocabularySense(id: UUID(), meaning: "Meaning", createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "word", dictionaryForm: "", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)
        let nodes = (0..<10).map { VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Node \($0)")]) }
        let document = VocabularyDocument(entries: [entry], semantics: .init(nodes: nodes,
            mappings: [.init(nodeID: nodes[0].id, senseID: sense.id)]))
        let state = try VocabularyEntrySaveState(validating: document)
        let before = try VocabularyEntryRowProjection(VocabularyPersistenceCodec.encode(state))
        var edited = document.semantics; edited.nodes[0].definition = "Changed"
        edited.nodes[0].labels.append(.init(text: "New label", language: .english, preferred: false))
        VocabularySemanticPolicy.removeNode(nodes[1].id, from: &edited)
        let change = try state.changingOrganization(.init(semantics: edited, basedOn: document.semantics))
        let rows = try before.applyingOrganization(change)
        #expect(rows.changed.count == 2 && rows.removed.count == 2)
        #expect(try VocabularyPersistenceCodec.decodeSaveState(rows.projection.rows(reviewTemplatesPresent: false)).document == change.state.document)
        #expect(try VocabularyPersistenceCodec.decode(before.rows(reviewTemplatesPresent: false)) == document)
        var note = change.state.entries[0]; note.senses[0].note = "e\u{301}"
        let noteChange = try change.state.replacing(note)
        let next = try rows.projection.applying(noteChange)
        #expect(try VocabularyPersistenceCodec.decode(next.projection.rows(reviewTemplatesPresent: false)) == noteChange.document)
    }
}
