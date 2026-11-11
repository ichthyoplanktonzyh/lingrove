import Foundation
import Testing
@testable import LingroveNotebook

/// Compare the restricted entry proof to the existing full validator. These fixtures exercise
/// dependencies and unrelated owners together, so skipped global validation cannot hide an
/// incorrect reconciliation or an index that drifts after several acknowledged changes.
struct VocabularySemanticEntryIndexTests {
    @Test func localEditsMatchFullReconciliationAcrossRepeatedChanges() throws {
        var state = try VocabularyEntrySaveState(validating: fixture())
        for step in 0..<6 {
            let previous = state.document
            var entry = state.entries[0]
            switch step {
            case 0: entry.senses[0].examples[0].meaning = "New evidence reading"
            case 1: entry.senses[0].examples[0].translation = "Only a translation"
            case 2: entry.senses[1].examples.append(entry.senses[0].examples.removeFirst())
            case 3: entry.senses[0].note = "Only a personal note"
            case 4: entry.senses[1].examples.removeFirst()
            default: entry.senses.removeFirst()
            }
            let change = try state.replacing(entry)
            var expected = previous
            expected.entries = [entry] + Array(state.entries.dropFirst())
            let full = try VocabularyDocumentValidation.prepare(expected, previous: previous)
            #expect(change.document == full)
            try VocabularyDocumentValidation.validate(change.document)
            #expect(change.document.semantics.nodes == previous.semantics.nodes)
            let unaffected = Set(state.entries.dropFirst().flatMap { $0.senses.map(\.id) })
            #expect(change.document.semantics.mappings.filter { unaffected.contains($0.senseID) } ==
                previous.semantics.mappings.filter { unaffected.contains($0.senseID) })
            #expect((step == 1 || step == 3) ? change.semanticChange.isEmpty : true)
            state = change.state
        }
    }

    @Test func wholeEntryRemovalCombinesRetirementsAndReleasesRemovedGraphIDs() throws {
        let document = fixture(), entry = document.entries[0]
        let state = try VocabularyEntrySaveState(validating: document)
        let change = try state.removingEntry(entry.id)
        var expected = document
        for sense in entry.senses { try VocabularySenseEditingPolicy.remove(entryID: entry.id, senseID: sense.id, from: &expected) }
        expected = try VocabularyDocumentValidation.prepare(expected, previous: document)
        #expect(change.document == expected)
        #expect(change.semanticChange.removedPatternIDs.count == 2)
        #expect(change.semanticChange.removedMappingIDs.count == 2)
        let released = try #require(change.semanticChange.removedPatternIDs.first)
        var other = change.state.entries[0]
        other.senses.append(.init(id: released, meaning: "A newly owned lexical ID", createdAt: Date(), updatedAt: Date()))
        let saved = try change.state.replacing(other)
        try VocabularyDocumentValidation.validate(saved.document)
    }

    private func fixture() -> VocabularyDocument {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let entries = (0..<3).map { word in
            VocabularyEntry(id: UUID(), expression: "word\(word)", dictionaryForm: "word\(word)", language: .english, kind: .word,
                senses: (0..<2).map { sense in
                    .init(id: UUID(), meaning: "Meaning \(sense)", examples: [.init(id: UUID(), sourceKind: .authored,
                        text: "Synthetic word\(word) usage \(sense)", translation: "", ranges: [], completeness: .sentence,
                        meaning: "Original evidence", createdAt: date)], createdAt: date, updatedAt: date)
                }, createdAt: date, updatedAt: date)
        }
        var document = VocabularyDocument(entries: entries)
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Shared meaning", language: .english)])
        let patterns = entries.flatMap(\.senses).map { VocabularyUsagePattern(senseID: $0.id, template: "A synthetic pattern") }
        let mappings = zip(patterns, entries.flatMap(\.senses)).map { pattern, sense in
            VocabularyMeaningMapping(nodeID: node.id, senseID: sense.id, patternID: pattern.id,
                evidenceIDs: sense.examples.map(\.id), provenance: .init(status: .confirmed))
        }
        document.semantics = .init(nodes: [node], patterns: patterns, mappings: mappings)
        return document
    }
}
