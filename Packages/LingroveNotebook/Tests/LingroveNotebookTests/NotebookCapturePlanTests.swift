import Foundation
import LingroveNotebook
import Testing

struct NotebookCapturePlanTests {
    @Test func capturesEvidenceAndClassificationUsingTheSharedMaterialSchema() throws {
        let categoryId = UUID()
        let task = try NotebookCaptureContract.decodeMaterial(Data("""
        {
          "defaults": {"language":"en","meaningLanguage":"en"},
          "meanings": [{"ref":"postpone","title":"Postponement","categories":["\(categoryId.uuidString)"]}],
          "entries": [{"expression":"take a rain check","kind":"expression","senses":[{
            "meaning":"postpone an invitation",
            "examples":[{"text":"I will take a rain check on dinner.","sourceKind":"captured"}],
            "associations":[{"meaning":"postpone"}]
          }]}]
        }
        """.utf8))
        let category = VocabularyCategory(id: categoryId, axis: .content, labels: [.init(text: "Scheduling", language: .english)])
        let document = VocabularyDocument(classification: .init(categories: [category]))
        let plan = try NotebookCapturePlan(task, document: document, now: Date()) { _ in UUID() }
        try VocabularyDocumentValidation.validate(plan.document)
        let entry = try #require(plan.document.collectedEntries.first)
        let sense = try #require(entry.senses.first)
        let example = try #require(sense.examples.first)
        let node = try #require(plan.document.semantics.nodes.first)
        #expect(example.text == "I will take a rain check on dinner.")
        #expect(example.sourceKind == .captured)
        #expect(plan.document.semantics.mappings.first?.evidenceIDs == [example.id])
        #expect(plan.document.classification.memberships.first?.nodeID == node.id)
        #expect(plan.document.classification.memberships.first?.categoryID == category.id)
    }
}
