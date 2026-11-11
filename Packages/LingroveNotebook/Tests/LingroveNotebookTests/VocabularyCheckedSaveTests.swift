import Foundation
import Testing
@testable import LingroveNotebook

/// These synthetic graphs compare the restricted writer with the complete validator. A
/// cached proof must reject the same broken relationships and retain competing evidence.
struct VocabularyCheckedSaveTests {
    @Test func batchHeadwordLookupReusesOwnersAndSeparatesLanguagesAndKinds() throws {
        let original = Self.fixture(), entryID = original.catalog[0].id
        let inputs: [VocabularyEntryInput] = [
            .init(expression: " word ", language: .english, kind: .word, meaning: "Second meaning"),
            .init(expression: "word", language: .english, kind: .word, meaning: "Third meaning"),
            .init(expression: "word", language: .chinese, kind: .word, meaning: "Another language"),
            .init(expression: "word", language: .english, kind: .expression, meaning: "Another kind"),
            .init(expression: "new", language: .english, kind: .word, meaning: "First"),
            .init(expression: "new", language: .english, kind: .word, meaning: "Second")]
        let plan = try VocabularyEntryInputPolicy.plan(inputs, into: original, now: Date(timeIntervalSince1970: 100))
        #expect(plan.result.addedEntries == 3 && plan.result.addedSenses == 6)
        #expect(plan.document.catalog.first { $0.id == entryID }?.senses.count == 3)
        #expect(plan.document.catalog.first { $0.expression == "new" }?.senses.count == 2)
        #expect(plan.document.sources == original.sources && plan.document.interpretations == original.interpretations)
        try VocabularyDocumentValidation.validate(plan.document)
    }

    @Test func scopedSemanticValidationMatchesCompleteValidationForDependentEdits() throws {
        let document = Self.fixture(), state = try VocabularyEntrySaveState(validating: document)
        var cases: [VocabularySemanticIndex] = []
        var graph = document.semantics
        graph.nodes[0].definition = "Edited definition"; cases.append(graph)
        graph = document.semantics; graph.nodes[0].roles = []; cases.append(graph)
        graph = document.semantics; graph.patterns[0].slots = []; cases.append(graph)
        graph = document.semantics; graph.nodes[0].kind = .function; cases.append(graph)
        graph = document.semantics; graph.nodes.removeFirst(); cases.append(graph)
        graph = document.semantics; graph.cues.removeAll(); cases.append(graph)
        graph = document.semantics
        graph.cueTargets.append(.init(cueID: graph.cues[0].id, nodeID: graph.nodes[0].id)); cases.append(graph)
        graph = document.semantics
        graph.nodes[0].roles.append(.init(id: graph.nodes[1].id, name: "Collision")); cases.append(graph)
        graph = document.semantics
        graph.nodes[0].roles.append(.init(id: document.catalog[0].senses[0].id, name: "Lexical collision")); cases.append(graph)
        graph = document.semantics
        graph.relations.append(.init(sourceID: graph.nodes[1].id, targetID: graph.nodes[0].id, kind: .narrower)); cases.append(graph)
        graph = document.semantics
        try VocabularySemanticPolicy.removeRole(graph.nodes[0].roles[0].id, nodeID: graph.nodes[0].id, from: &graph)
        cases.append(graph)
        graph = document.semantics
        VocabularySemanticPolicy.removeNode(graph.nodes[0].id, from: &graph); cases.append(graph)
        for edited in cases {
            let edit = try VocabularyOrganizationEdit(semantics: edited, basedOn: document.semantics)
            let result = try edit.applying(semantics: document.semantics, classification: document.classification)
            var candidate = document; candidate.semantics = result.semantics; candidate.classification = result.classification
            let expected = Result { try VocabularyDocumentValidation.validate(candidate) }
            let actual = Result { try state.changingOrganization(edit) }
            switch (expected, actual) {
            case (.success, .success(let change)):
                #expect(change.state.document == candidate)
            case (.failure, .failure): break
            default: Issue.record("Scoped and complete validation disagreed for \(edited)")
            }
        }
    }

    @Test func tagRemovalRetainsEvidenceCandidatesAndThePreviousState() throws {
        var document = Self.fixture()
        document.catalog[0].senses[0].tags = ["keep", "remove"]
        var candidate = document.interpretations[0]; candidate.id = UUID(); candidate.status = .candidate
        document.interpretations.append(candidate)
        let before = try VocabularyEntrySaveState(validating: document)
        let change = try before.removingTag("remove", now: Date(timeIntervalSince1970: 100))
        #expect(change.entryIDs == [document.catalog[0].id])
        #expect(before.document == document && before.entries[0].senses[0].tags == ["keep", "remove"])
        #expect(change.state.document.sources == document.sources)
        #expect(change.state.document.interpretations == document.interpretations)
        #expect(change.state.entries == change.state.document.entries)
        #expect(try change.state.removingTag("remove").entryIDs.isEmpty)
        try VocabularyDocumentValidation.validate(change.state.document)
    }

    @Test func removingAnEmptyEntryReallyRetiresItsIdentity() throws {
        var document = Self.fixture()
        var empty = document.catalog[0]
        empty = .init(id: UUID(), expression: "empty entry", dictionaryForm: "", language: .english,
            kind: .expression, senses: [], createdAt: empty.createdAt, updatedAt: empty.updatedAt)
        document.catalog.append(empty)
        let state = try VocabularyEntrySaveState(validating: document)
        let removed = try state.removingEntry(empty.id)
        #expect(!removed.document.catalog.contains { $0.id == empty.id })
        let reinserted = try removed.state.replacing(empty)
        try VocabularyDocumentValidation.validate(reinserted.document)
    }

    static func fixture() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 10)
        let example = VocabularyExample(id: UUID(), text: "An example.", translation: "", ranges: [],
            completeness: .sentence, meaning: "", createdAt: now)
        let sense = VocabularySense(id: UUID(), meaning: "A meaning", examples: [example], createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "word", dictionaryForm: "", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)
        let role = VocabularyMeaningRole(id: UUID(), name: "Agent")
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "First")], roles: [role])
        let other = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Second")])
        let slot = VocabularyPatternSlot(id: UUID(), name: "subject")
        let pattern = VocabularyUsagePattern(id: UUID(), senseID: sense.id, template: "subject acts", slots: [slot])
        let mapping = VocabularyMeaningMapping(nodeID: node.id, senseID: sense.id, patternID: pattern.id,
            roleBindings: [.init(roleID: role.id, slotID: slot.id)], evidenceIDs: [example.id])
        let cue = VocabularyRetrievalCue(id: UUID(), text: "cue")
        return .init(entries: [entry], semantics: .init(nodes: [node, other], patterns: [pattern], mappings: [mapping],
            relations: [.init(sourceID: node.id, targetID: other.id, kind: .narrower)], cues: [cue],
            cueTargets: [.init(cueID: cue.id, nodeID: node.id)]))
    }
}
