import Foundation
import LingroveNotebook
import Testing

struct VocabularyContentEditingPolicyTests {
    private func edit(_ fields: [String: Any]) throws -> VocabularyContentEdit {
        try JSONDecoder().decode(VocabularyContentEdit.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func plainReadsAndFragmentEditsPreserveImagesAndUnmentionedFormatting() throws {
        let now = Date(), part = UUID()
        let image = VocabularyContentBlock(content: .image(.init(digest: String(repeating: "a", count: 64), width: 1, height: 1, byteCount: 8), caption: "Diagram"))
        var sense = VocabularySense(id: UUID(), meaning: "bank", alternateMeanings: [.init(text: "OBSOLETE", language: .english)],
            content: [.init(id: part, content: .text(.init(text: "🏦 old bank", style: .heading,
                runs: [.init(location: 3, length: 3, bold: true), .init(location: 7, length: 4, italic: true)]))), image],
            createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "bank", dictionaryForm: "bank", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)
        let before = VocabularyDocument(entries: [entry])
        let read = try NotebookSenseProjection(before).sense(sense.id)
        let json = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(json.contains("🏦 old bank") && json.contains("imageID"))
        #expect(!json.contains("OBSOLETE") && !json.contains("bold") && !json.contains("runs") && !json.contains("style"))
        #expect(throws: (any Error).self) { try VocabularyContentEditingPolicy.replacePlainExplanation("Replacement", in: &sense, id: UUID()) }
        try VocabularyContentEditingPolicy.apply([edit(["blockID": part.uuidString, "find": "old", "replacement": "newer"])], to: &sense)
        guard case let .text(value) = try #require(sense.content?.first).content else { Issue.record("Text missing"); return }
        #expect(value.text == "🏦 newer bank" && value.style == .heading)
        #expect(value.runs == [.init(location: 3, length: 5, bold: true), .init(location: 9, length: 4, italic: true)])
        #expect(sense.content?.last == image)
        var after = before; after.entries[0].senses[0] = sense
        let preview = try NotebookChangePreview.make(before: before, after: after)
        guard case let .object(root) = preview, case let .array(changes) = root["senses"] else { Issue.record("Diff missing"); return }
        #expect(changes.count == 1)
        let diff = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        #expect(diff.contains("🏦 old bank") && diff.contains("🏦 newer bank") && diff.contains("Diagram"))
    }

    @Test func ambiguousOrStaleFragmentsFailWithoutPublishingPartialEdits() throws {
        let now = Date(), part = UUID()
        var sense = VocabularySense(id: UUID(), meaning: "bank", content: [.init(id: part, content: .text(.init(text: "bank and bank")))],
            createdAt: now, updatedAt: now)
        let before = sense
        for find in ["bank", "missing"] {
            #expect(throws: (any Error).self) {
                try VocabularyContentEditingPolicy.apply([edit(["blockID": part.uuidString, "find": find, "replacement": "new"])], to: &sense)
            }
            #expect(sense == before)
        }
    }
}
