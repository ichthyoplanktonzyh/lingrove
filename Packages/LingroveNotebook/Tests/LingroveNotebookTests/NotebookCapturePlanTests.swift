import Foundation
import LingroveNotebook
import Testing

struct NotebookCapturePlanTests {
    @Test func editingAnExistingResourceRetainsItsUnmentionedFields() throws {
        let id = UUID()
        let entry = VocabularyEntry(id: id, expression: "take a rain check", dictionaryForm: "take a rain check",
            language: .english, kind: .expression, senses: [], createdAt: Date(), updatedAt: Date())
        var document = VocabularyDocument(catalog: [entry], sources: [], occurrences: [], interpretations: [])
        let patch = NotebookResourcePut(resource: "entries", value: .object([
            "id": .string(id.uuidString), "expression": .string("rain check"),
        ]))
        _ = try NotebookResources.put(patch, in: &document, now: Date())
        let updated = try #require(document.catalog.first)
        #expect(updated.expression == "rain check")
        #expect(updated.language == .english)
        #expect(updated.dictionaryForm == "take a rain check")
        try VocabularyDocumentValidation.validate(document)
    }

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
        let entry = try #require(plan.document.entries.first)
        let sense = try #require(entry.senses.first)
        let example = try #require(sense.examples.first)
        let node = try #require(plan.document.semantics.nodes.first)
        #expect(example.text == "I will take a rain check on dinner.")
        #expect(example.sourceKind == .captured)
        #expect(plan.document.semantics.mappings.first?.evidenceIDs == [example.id])
        #expect(plan.document.classification.memberships.first?.nodeID == node.id)
        #expect(plan.document.classification.memberships.first?.categoryID == category.id)
    }
    @Test func senseExplanationIsCanonicalAndExamplesCannotSupplyAnotherMeaning() throws {
        let input = Data(#"""
        {"defaults":{"language":"en"},"entries":[{"expression":"put off","senses":[{
          "meaning":"postpone", "explanation":"Use with an event or an activity.", "note":"My reminder",
          "examples":[{"text":"We put off the meeting.","translation":"我们推迟了会议。"}]
        }]}]}
        """#.utf8)
        let task = try NotebookCaptureContract.decodeMaterial(input)
        let plan = try NotebookCapturePlan(task, document: .init(), now: Date()) { _ in UUID() }
        try VocabularyDocumentValidation.validate(plan.document)
        let sense = try #require(plan.document.entries.first?.senses.first)
        #expect(sense.meaning == "postpone")
        #expect(sense.note == "My reminder")
        #expect(sense.content?.count == 1)
        guard case .text(let body) = try #require(sense.content?.first).content else {
            Issue.record("Expected the authored sense explanation"); return
        }
        #expect(body.text == "Use with an event or an activity.")
        #expect(sense.examples.first?.meaning == "")
        #expect(sense.examples.first?.explanations.isEmpty == true)
        #expect(sense.explanations.isEmpty)
        // Obsolete authoring fields fail closed instead of being silently copied or migrated.
        let obsolete = String(decoding: input, as: UTF8.self)
            .replacingOccurrences(of: "We put off the meeting.\"", with: "We put off the meeting.\",\"meaning\":\"postpone this meeting\"")
        #expect(throws: (any Error).self) {
            try NotebookCaptureContract.decodeMaterial(Data(obsolete.utf8))
        }
    }

    @Test func captureCannotReplaceExistingSenseExplanation() throws {
        let now = Date(), senseID = UUID()
        let sense = VocabularySense(id: senseID, meaning: "postpone",
            content: [.init(content: .text(.init(text: "Saved explanation")))], createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "put off", dictionaryForm: "put off",
            language: .english, kind: .word, senses: [sense], createdAt: now, updatedAt: now)
        let task = try NotebookCaptureContract.decodeMaterial(Data("""
        {"defaults":{"language":"en"},"entries":[{"expression":"put off","senses":[{
          "id":"\(senseID.uuidString)","explanation":"Unreviewed replacement"
        }]}]}
        """.utf8))
        let document = VocabularyDocument(entries: [entry])
        #expect(throws: (any Error).self) {
            try NotebookCapturePlan(task, document: document, now: now) { _ in UUID() }
        }
        #expect(document.entries.first?.senses.first?.content == sense.content)
    }

}
