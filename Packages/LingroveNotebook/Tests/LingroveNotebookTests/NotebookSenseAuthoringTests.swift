import Foundation
import LingroveNotebook
import Testing

struct NotebookSenseAuthoringTests {
    private func capture(_ material: [String: Any], into document: VocabularyDocument = .init()) throws -> VocabularyDocument {
        let task = try NotebookCaptureContract.decodeMaterial(JSONSerialization.data(withJSONObject: material))
        let plan = try NotebookCapturePlan(task, document: document, now: Date()) { _ in UUID() }
        try VocabularyDocumentValidation.validate(plan.document)
        return plan.document
    }

    private func material(_ sense: [String: Any]) -> [String: Any] {
        ["defaults": ["language": "en"], "entries": [["expression": "bank", "senses": [sense]]]]
    }

    @Test func independentSourcesWithEqualTextRemainDistinct() throws {
        let first = try capture(material(["meaning": "financial institution", "examples": [[
            "text": "The bank is open.", "sourceKind": "captured", "source": "Article A"
        ]]]))
        let second = try capture(material(["meaning": "financial institution", "examples": [[
            "text": "The bank is open.", "sourceKind": "captured", "source": "Article B"
        ]]]), into: first)
        #expect(second.catalog[0].senses.count == 2 && second.sources.count == 2)
        #expect(Set(second.interpretations.map(\.provenance.source)) == ["Article A", "Article B"])
        #expect(Set(second.entries[0].examples.map(\.sourceID)).count == 2)
    }

    @Test func captureAndAppendShareExplicitSourceAndTranslationRules() throws {
        let first = try capture(material(["meaning": "financial institution", "examples": [[
            "text": "The bank is open.", "translation": "银行开门了。", "translationLanguage": "zh-Hans", "source": "Article A"
        ]]]))
        let senseID = first.catalog[0].senses[0].id, sourceID = first.sources[0].id
        let translated: [String: Any] = ["text": "The bank is open.", "sourceID": sourceID.uuidString,
            "translation": "这家银行正在营业。", "translationLanguage": "zh-Hans"]
        let captured = try capture(material(["id": senseID.uuidString, "examples": [translated]]), into: first)
        var appended = first
        let input = try JSONDecoder().decode(NotebookCaptureExample.self, from: JSONSerialization.data(withJSONObject: translated))
        let retained = try NotebookExampleWriting.append(input, entry: first.catalog[0], senseID: senseID,
            in: &appended, id: UUID(), occurrenceID: UUID(), now: Date())
        #expect(retained == first.interpretations[0].id)
        #expect(appended.interpretations == captured.interpretations)
        #expect(appended.sources == first.sources && appended.occurrences == first.occurrences)
        #expect(appended.interpretations[0].translationVariants == [.init(text: "这家银行正在营业。", language: .chinese)])
        var conflicting = input; conflicting.completeness = "fragment"
        let unchanged = appended
        #expect(throws: (any Error).self) {
            try NotebookExampleWriting.append(conflicting, entry: first.catalog[0], senseID: senseID,
                in: &appended, id: UUID(), occurrenceID: UUID(), now: Date())
        }
        #expect(appended == unchanged)
    }

    @Test func sourceCorrectionsRetainExampleIdentityAndOriginalEvidence() throws {
        var document = try capture(material(["meaning": "financial institution", "examples": [["text": "The bank is open."]]]))
        let before = document
        let patch = try JSONDecoder().decode(NotebookExampleEdit.self, from: JSONSerialization.data(withJSONObject: [
            "id": document.interpretations[0].id.uuidString, "text": "The bank opens early.", "source": "Corrected quotation"
        ]))
        try NotebookExampleWriting.edit(patch, entry: document.catalog[0], senseID: document.catalog[0].senses[0].id,
            in: &document, sourceID: UUID(), occurrenceID: UUID(), now: Date())
        try VocabularyDocumentValidation.validate(document)
        #expect(document.interpretations[0].id == before.interpretations[0].id)
        #expect(document.sources.contains(before.sources[0]) && document.occurrences.contains(before.occurrences[0]))
        #expect(document.entries[0].examples[0].text == "The bank opens early.")
        #expect(document.interpretations[0].provenance.source == "Corrected quotation")
    }

    @Test func ordinaryContractsRejectDuplicateExplanationFields() throws {
        #expect(throws: (any Error).self) {
            try capture(["defaults": ["language": "en"], "meanings": [["ref": "bank", "title": "Banking"]],
                "entries": [["expression": "bank", "senses": [["meaning": "financial institution",
                    "associations": [["meaning": "bank", "nuance": "Old duplicate explanation"]]]]]]])
        }
        for (resource, key) in [("interpretations", "meaning"), ("patterns", "note"), ("mappings", "nuance"), ("senses", "alternateMeanings")] {
            #expect(try NotebookResourceContract.shape(resource).fields[key] == nil)
        }
    }
}
