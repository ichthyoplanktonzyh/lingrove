import Foundation
import Testing
@testable import Lingrove

/// Simplified forms must retain knowledge the learner never sees or edits. These cases use
/// multilingual labels and restricted mappings so loss cannot hide behind an empty fixture.
@MainActor
struct VocabularySemanticEditingTests {
    @Test func renamingKeepsIdentityLanguagesRolesAndUnconfirmedProvenance() {
        var original = VocabularySemanticTests.fixture().semantics.nodes[0]
        original.kind = .function
        original.scopeNote = "Retained boundary"
        original.provenance = .init(origin: .model, status: .proposed, source: "Original source", confidence: 0.7)
        let now = Date()
        let edited = VocabularySemanticEditingPolicy.rename(original, title: " 请求改期 ", definition: " New note ", now: now)
        var expected = original
        expected.labels[0].text = "请求改期"; expected.definition = "New note"; expected.updatedAt = now
        #expect(edited == expected)
    }

    @Test func classificationEditsCannotBroadenOrDiscardHiddenRestrictions() {
        let document = VocabularySemanticTests.fixture()
        var original = document.semantics.mappings[0]
        original.provenance = .init(origin: .model, status: .proposed, source: "A source", confidence: 0.8)
        let unchanged = VocabularySemanticEditingPolicy.classify(original, under: document.semantics.nodes[0],
            conditions: original.conditions, nuance: original.nuance)
        #expect(unchanged == original)
        let moved = VocabularySemanticEditingPolicy.classify(original, under: document.semantics.nodes[1],
            conditions: original.conditions, nuance: "A personal note")
        #expect(moved.patternID == original.patternID && moved.senseID == original.senseID)
        #expect(moved.evidenceIDs == original.evidenceIDs && moved.provenance == original.provenance)
        #expect(moved.roleBindings.isEmpty && moved.conditions == original.conditions)
    }

    @Test func restrictedMappingDoesNotBorrowAnUnrelatedRepresentativeExample() {
        let document = VocabularySemanticTests.fixture(), sense = document.entries[0].senses[0]
        var mapping = document.semantics.mappings[0]
        #expect(VocabularySemanticEditingPolicy.example(for: mapping, sense: sense) == sense.examples[0])
        mapping.evidenceIDs = [UUID()]
        #expect(VocabularySemanticEditingPolicy.example(for: mapping, sense: sense) == nil)
        mapping.evidenceIDs = []
        #expect(VocabularySemanticEditingPolicy.example(for: mapping, sense: sense) == nil)
        mapping.patternID = nil
        #expect(VocabularySemanticEditingPolicy.example(for: mapping, sense: sense) == sense.examples[0])
    }
}
