import Foundation
import LingroveNotebook
import Testing

struct NotebookSenseWritingTests {
    private func fixture() throws -> VocabularyDocument {
        let task = try NotebookCaptureContract.decodeMaterial(Data("""
        {"defaults":{"language":"en"},"entries":[{"expression":"bank","senses":[{
          "meaning":"financial institution","explanation":"An old explanation.",
          "examples":[{"text":"The bank is open.","translation":"银行开门了。"}]
        }]}]}
        """.utf8))
        return try NotebookCapturePlan(task, document: .init(), now: Date()) { _ in UUID() }.document
    }

    @Test func completeUpdateRetainsIdentityAndOriginalEvidence() throws {
        var document = try fixture()
        let before = document
        let entry = document.catalog[0], sense = entry.senses[0]
        let patch: NotebookToolJSON = .object([
            "entryID": .string(entry.id.uuidString), "senseID": .string(sense.id.uuidString), "expectedRevision": .integer(7),
            "explanation": .string("Current explanation."),
            "exampleEdits": .array([.object(["id": .string(document.interpretations[0].id.uuidString),
                "text": .string("The bank opens early.")])])
        ])
        try NotebookSenseWriting.update(.decode(patch), in: &document, revision: 7, now: Date()) { _ in UUID() }
        try VocabularyDocumentValidation.validate(document)
        #expect(document.catalog[0].senses[0].id == sense.id)
        #expect(document.catalog[0].senses[0].content?.first?.id == sense.content?.first?.id)
        #expect(document.interpretations[0].id == before.interpretations[0].id)
        #expect(document.sources.contains(before.sources[0]))
        #expect(document.entries[0].examples[0].text == "The bank opens early.")
    }

    @Test func failureAfterFieldEditAndStaleRevisionLeaveDocumentUntouched() throws {
        var document = try fixture()
        let before = document, entry = document.catalog[0], sense = entry.senses[0]
        let update = NotebookSenseUpdate(entryID: entry.id, senseID: sense.id, expectedRevision: 7,
            explanation: "Must not persist", unlinkNodes: [UUID()])
        for revision: UInt64 in [7, 8] {
            #expect(throws: (any Error).self) {
                try NotebookSenseWriting.update(update, in: &document, revision: revision, now: Date()) { _ in UUID() }
            }
            #expect(document == before)
        }
    }
}
