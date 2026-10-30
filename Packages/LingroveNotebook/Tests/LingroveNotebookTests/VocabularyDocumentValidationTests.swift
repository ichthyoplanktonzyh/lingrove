import Foundation
import LingroveNotebook
import Testing

/// Public-contract tests for document validation shared by the Mac archive and notebook store.
/// Synthetic stable identities keep these boundary cases independent of a platform archive.
struct VocabularyDocumentValidationTests {
    @Test func emptyReviewNeedsNoAnkiSetupAndPersistedReceiptsKeepLegacyValidation() throws {
        let senseID = Self.id(101)
        let unboundReview = VocabularyReview(plan: ReviewPlan())
        try VocabularyReviewValidation.validate(unboundReview)
        try VocabularyDocumentValidation.validate(VocabularyDocument(entries: [
            Self.entry(id: Self.id(100), senseID: senseID, review: unboundReview)
        ]))

        let hash = String(repeating: "a", count: 64)
        let audio = ReviewAudioReceipt(
            fingerprint: hash,
            textHash: hash,
            endpoint: "http://localhost:8765",
            profile: "local-test-profile",
            filename: "lingrove-\(hash).mp3"
        )
        let binding = Self.binding(id: Self.id(102), senseID: senseID)
        let review = VocabularyReview(
            plan: ReviewPlan(audioReceipts: [.expression: audio]),
            bindings: [binding],
            activeBindingID: binding.id
        )
        try VocabularyDocumentValidation.validate(VocabularyDocument(entries: [
            Self.entry(id: Self.id(103), senseID: senseID, review: review)
        ]))

        #expect(VocabularyReviewValidation.legacyAnkiEndpoint("http://localhost:8765/")?.host == "localhost")
        #expect(VocabularyReviewValidation.legacyAnkiEndpoint("http://anki.example") == nil)
        #expect(VocabularyReviewValidation.legacyAnkiEndpoint("https://localhost:8765") == nil)
        #expect(VocabularyReviewValidation.validAudioFilename("lingrove-\(hash).mp3"))
        #expect(!VocabularyReviewValidation.validAudioFilename("bank-expression-fixture.mp3"))

        let remoteAudio = ReviewAudioReceipt(
            fingerprint: hash,
            textHash: hash,
            endpoint: "http://anki.example",
            profile: "local-test-profile",
            filename: "lingrove-\(hash).mp3"
        )
        var invalidReview = review
        invalidReview.plan = ReviewPlan(audioReceipts: [.expression: remoteAudio])
        #expect(throws: VocabularyError.invalidArchive) {
            try VocabularyReviewValidation.validate(invalidReview)
        }
    }

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

    @Test func globalIdentityCollisionsFailWhileBindingAndTemplateIDsRemainScoped() throws {
        let localID = Self.id(401)
        let senseID = Self.id(402)
        let localLayout = ReviewLayout(front: [
            ReviewCardPart(id: localID, source: .expression)
        ])
        let binding = Self.binding(id: localID, senseID: senseID)
        let review = VocabularyReview(
            plan: ReviewPlan(id: Self.id(403), layout: localLayout),
            bindings: [binding],
            activeBindingID: localID
        )
        let template = ReviewLayoutTemplate(
            id: localID,
            name: "Reusable layout",
            layout: ReviewLayout(front: [ReviewCardPart(id: localID, source: .expression)])
        )
        let valid = VocabularyDocument(
            entries: [Self.entry(id: Self.id(404), senseID: senseID, review: review)],
            reviewTemplates: [template]
        )
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

    @Test func imageOwnershipIncludesSensePreservedFlexibleAndTemplateLayouts() throws {
        let senseImage = Self.imageBlock("1", id: Self.id(501))
        let currentPlanImage = Self.imageBlock("2", id: Self.id(502))
        let preservedPlanImage = Self.imageBlock("3", id: Self.id(503))
        let flexibleCardImage = Self.imageBlock("4", id: Self.id(504))
        let templateImage = Self.imageBlock("5", id: Self.id(505))

        let review = VocabularyReview(
            plan: ReviewPlan(
                id: Self.id(506),
                layout: ReviewLayout(front: [Self.customPart(id: Self.id(507), content: currentPlanImage)])
            ),
            preservedPlans: [ReviewPlan(
                id: Self.id(508),
                layout: ReviewLayout(back: [Self.customPart(id: Self.id(509), content: preservedPlanImage)])
            )]
        )
        let flexibleCard = VocabularyReview(plan: ReviewPlan(
            id: Self.id(510),
            layout: ReviewLayout(front: [Self.customPart(id: Self.id(511), content: flexibleCardImage)])
        ))
        let template = ReviewLayoutTemplate(
            id: Self.id(512),
            name: "Template with image",
            layout: ReviewLayout(back: [Self.customPart(id: Self.id(513), content: templateImage)])
        )
        let document = VocabularyDocument(
            entries: [Self.entry(
                id: Self.id(514),
                senseID: Self.id(515),
                content: [senseImage],
                review: review,
                reviewCards: [flexibleCard]
            )],
            reviewTemplates: [template]
        )

        let digests = Set(VocabularyDocumentValidation.imageReferences(document).map(\.digest))
        #expect(digests == Set((1...5).map { String(repeating: String($0), count: 64) }))
        try VocabularyDocumentValidation.validateMediaContent(document)
        try VocabularyDocumentValidation.validate(document)
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
        content: [VocabularyContentBlock]? = nil,
        review: VocabularyReview? = nil,
        reviewCards: [VocabularyReview]? = nil
    ) -> VocabularyEntry {
        let sense = VocabularySense(
            id: senseID,
            meaning: "a meaning",
            explanations: explanations,
            review: review,
            reviewCards: reviewCards,
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

    private static func binding(id: UUID, senseID: UUID) -> AnkiNoteBinding {
        AnkiNoteBinding(
            id: id,
            originSenseID: senseID,
            endpoint: "http://127.0.0.1:8765",
            profile: "Local Anki",
            noteID: 42,
            model: "Basic",
            deck: "Vocabulary",
            identityField: ReviewField.identity.rawValue,
            mapping: [.identity: ReviewField.identity.rawValue],
            fields: [ReviewField.identity.rawValue: senseID.uuidString.lowercased()]
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

    private static func customPart(id: UUID, content: VocabularyContentBlock) -> ReviewCardPart {
        ReviewCardPart(id: id, source: .custom, content: [content])
    }

    private static func id(_ suffix: Int) -> UUID {
        guard let value = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix)) else {
            fatalError("The synthetic test UUID suffix must produce a valid UUID.")
        }
        return value
    }
}
