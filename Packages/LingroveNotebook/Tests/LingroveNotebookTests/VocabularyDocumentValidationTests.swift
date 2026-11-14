import Foundation
import LingroveNotebook
import Testing

/// Public-contract tests for document validation shared by the Mac archive and notebook store.
/// Synthetic stable identities keep these boundary cases independent of a platform archive.
struct VocabularyDocumentValidationTests {

    @Test func strictValidationRejectsStaleExplanationWhilePreparePrunesAndKeepsStableIDs() throws {
        var originalEntry = Self.entry(id: Self.id(201), senseID: Self.id(202))
        let originalSense = try #require(originalEntry.senses.first)
        let input = VocabularyExplanationIdentity.input(for: originalEntry, sense: originalSense, example: nil)
        originalEntry.senses[0].explanations = [
            .init(
                id: Self.id(203),
                input: input,
                language: .japanese,
                result: .init(meaning: "a financial institution", explanation: "A place that keeps money."),
                model: "fixture-model",
                createdAt: Self.referenceDate
            )
        ]
        let previous = VocabularyDocument(entries: [originalEntry])
        var editedEntry = try #require(previous.entries.first)
        editedEntry.expression = "credit union"
        var edited = previous
        edited.entries[0] = editedEntry

        #expect(throws: VocabularyError.invalidArchive) {
            try VocabularyDocumentValidation.validate(edited)
        }
        // Media is staged before explanation reconciliation, so this narrower boundary must
        // permit a legitimate edit whose old explanation is still attached to the draft.
        try VocabularyDocumentValidation.validateMediaContent(edited)

        let prepared = try VocabularyDocumentValidation.prepare(edited, previous: previous)
        #expect(prepared.entries[0].expression == "credit union")
        #expect(prepared.entries[0].id == originalEntry.id)
        #expect(prepared.entries[0].senses[0].id == originalEntry.senses[0].id)
        #expect(prepared.entries[0].senses[0].explanations.isEmpty)
        try VocabularyDocumentValidation.validate(prepared)
    }

    @Test func prepareRejectsBrokenCanonicalGraphInsteadOfRepairingIt() {
        let previous = VocabularyDocument()
        var broken = previous
        broken.interpretations.append(.init(
            id: Self.id(301),
            occurrenceID: Self.id(302),
            createdAt: Self.referenceDate
        ))

        #expect(throws: VocabularyError.invalidArchive) {
            try VocabularyDocumentValidation.prepare(broken, previous: previous)
        }
        #expect(broken.interpretations.count == 1)
    }

    @Test func globalCorpusIdentityCollisionsFail() throws {
        let valid = VocabularyDocument(entries: [Self.entry(id: Self.id(404), senseID: Self.id(402))])
        try VocabularyDocumentValidation.validate(valid)

        let collisionID = Self.id(405)
        let collidingContent = VocabularyContentBlock(
            id: collisionID,
            content: .text(.init(text: "Meaning"))
        )
        let invalid = VocabularyDocument(entries: [
            Self.entry(
                id: Self.id(406),
                senseID: collisionID,
                content: [collidingContent]
            )
        ])
        #expect(throws: VocabularyError.invalidArchive) {
            try VocabularyDocumentValidation.validate(invalid)
        }
    }

    @Test func imageOwnershipFollowsCorpusContentOnly() throws {
        let image = Self.imageBlock("1", id: Self.id(501))
        let document = VocabularyDocument(entries: [Self.entry(id: Self.id(514), senseID: Self.id(515), content: [image])])
        #expect(Set(VocabularyDocumentValidation.imageReferences(document).map(\.digest)) == [String(repeating: "1", count: 64)])
        try VocabularyDocumentValidation.validateMediaContent(document)
        try VocabularyDocumentValidation.validate(document)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        #expect(object["reviewTemplates"] == nil)
    }

    @Test func explanationIdentityDistinguishesNoContextAndUnknownUsage() throws {
        let noContext = VocabularyExplanationIdentity.input(
            expression: "went",
            dictionaryForm: "go",
            language: .english,
            kind: .word,
            example: nil
        )
        #expect(noContext.target == "went")
        #expect(noContext.dictionaryForm == "go")
        #expect(noContext.context == "went")
        #expect(noContext.contextKind == .none)
        #expect(noContext.occurrenceIdentity == nil)
        #expect(noContext.ranges == [VocabularyTextRange(NSRange(location: 0, length: 4))])

        let usage = VocabularyExample(
            id: Self.id(601),
            text: "🐈 went home",
            translation: "",
            ranges: [VocabularyTextRange(NSRange(location: 3, length: 4))],
            completeness: .unknown,
            meaning: "",
            createdAt: Self.referenceDate
        )
        let withUnknownContext = VocabularyExplanationIdentity.input(
            expression: "went",
            dictionaryForm: "go",
            language: .english,
            kind: .word,
            example: usage
        )
        #expect(withUnknownContext.target == "went")
        #expect(withUnknownContext.dictionaryForm == "go")
        #expect(withUnknownContext.context == usage.text)
        #expect(withUnknownContext.contextKind == .unknown)
        #expect(withUnknownContext.ranges == usage.ranges)
        #expect(withUnknownContext.occurrenceIdentity == VocabularyIdentityPolicy.exampleKey(usage))
        #expect(withUnknownContext != noContext)
    }

    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func entry(
        id: UUID,
        senseID: UUID,
        expression: String = "bank",
        dictionaryForm: String? = nil,
        explanations: [LearningExplanationRecord] = [],
        content: [VocabularyContentBlock]? = nil
    ) -> VocabularyEntry {
        let sense = VocabularySense(
            id: senseID,
            meaning: "a meaning",
            explanations: explanations,
            content: content,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
        return VocabularyEntry(
            id: id,
            expression: expression,
            dictionaryForm: dictionaryForm ?? expression,
            language: .english,
            kind: .word,
            senses: [sense],
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
    }

    private static func imageBlock(_ hexDigit: String, id: UUID) -> VocabularyContentBlock {
        let image = VocabularyImageReference(
            digest: String(repeating: hexDigit, count: 64),
            width: 32,
            height: 24,
            byteCount: 256
        )
        return VocabularyContentBlock(id: id, content: .image(image, caption: "caption"))
    }

    private static func id(_ suffix: Int) -> UUID {
        guard let value = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix)) else {
            fatalError("The synthetic test UUID suffix must produce a valid UUID.")
        }
        return value
    }
}
