import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// A deterministic, strict-valid notebook graph shared by wire contract tests.
/// Keeping construction in one boundary makes identity, rank, and private overlay
/// relationships visible together instead of assembling partial, invalid row samples.
enum VocabularyWireTestFixture {
    static let notebookID = id(1)

    static let targetEntryID = id(102)
    static let otherEntryID = id(101)
    static let targetSenseID = id(202)
    static let mergedSenseID = id(203)
    static let otherSenseID = id(201)

    static let acceptedInterpretationID = id(321)
    static let candidateInterpretationID = id(322)

    static let currentPlanID = id(401)
    static let preservedPlanID = id(402)
    static let cardPlanID = id(403)
    static let legacyDraftID = Self.targetSenseID.uuidString.lowercased() + ":legacy"

    static let currentBindingID = id(411)
    static let mergedBindingID = id(412)
    static let currentReceiptFingerprint = String(repeating: "a", count: 64)
    static let preservedReceiptFingerprint = String(repeating: "b", count: 64)
    static let currentReceiptFilename = "lingrove-" + String(repeating: "c", count: 64) + ".mp3"
    static let preservedReceiptFilename = "lingrove-" + String(repeating: "d", count: 64) + ".wav"

    enum BindingScenario {
        case multipleWithMergedActive
        case singleWithoutActive
    }

    /// Returns a graph that passes the same strict validator used before projection.
    /// The target is intentionally ranked before a lower-UUID entry, and the second
    /// sense represents a merged-away identity without changing its private binding origin.
    static func document(bindingScenario: BindingScenario = .multipleWithMergedActive) throws -> VocabularyDocument {
        let createdAt = Date(timeIntervalSinceReferenceDate: 811_111_111.125)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 811_111_113.375)
        let savedAt = Date(timeIntervalSinceReferenceDate: 811_111_117.625)

        let acceptedSource = VocabularySourceSnapshot(
            id: id(301), text: "They remember the phrase. A\u{0000}cafe\u{0301} 👩🏽‍💻.", kind: .captured,
            appBundleIdentifier: "com.example.reader", encounteredAt: Date(timeIntervalSinceReferenceDate: 811_111_119.1234567)
        )
        let candidateSource = VocabularySourceSnapshot(
            id: id(302), text: "She recalls cafe\u{0301} 👩🏽‍💻.", kind: .authored,
            appBundleIdentifier: nil, encounteredAt: Date(timeIntervalSinceReferenceDate: 811_111_121.875)
        )
        let acceptedOccurrence = VocabularySourceOccurrence(
            id: id(311), sourceID: acceptedSource.id, ranges: [VocabularyTextRange(NSRange(location: 5, length: 8))]
        )
        let candidateOccurrence = VocabularySourceOccurrence(
            id: id(312), sourceID: candidateSource.id, ranges: [VocabularyTextRange(NSRange(location: 4, length: 21))]
        )

        let acceptedClaim = VocabularyInterpretation(
            id: Self.acceptedInterpretationID, occurrenceID: acceptedOccurrence.id, senseID: targetSenseID,
            status: .accepted, meaning: "to bring a fact back to mind", meaningLanguage: .english,
            meaningOrigin: .user, translation: "记起", translationLanguage: .chinese,
            translationVariants: [.init(text: "想起", language: .chinese)], completeness: .sentence,
            provenance: .init(origin: .user, status: .confirmed, source: "Fixture author", confidence: 0.95),
            createdAt: Date(timeIntervalSinceReferenceDate: 811_111_123.25)
        )
        let acceptedExample = VocabularyNotebookProjection.example(
            acceptedClaim, occurrence: acceptedOccurrence, source: acceptedSource
        )
        let acceptedExplanation = Self.explanation(
            id: id(332),
            input: VocabularyExplanationIdentity.input(
                expression: "remember", dictionaryForm: "remember", language: nil, kind: .word,
                example: acceptedExample
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 811_111_127.5)
        )
        var accepted = acceptedClaim
        accepted.explanations = [acceptedExplanation]

        let candidateInput = LearningExplanationInput(
            target: "recalls cafe\u{0301} 👩🏽‍💻", dictionaryForm: "recall", language: .english, kind: .word,
            context: candidateSource.text, ranges: candidateOccurrence.ranges,
            contextKind: .sentence, occurrenceIdentity: "local-only:candidate-explanation"
        )
        let candidate = VocabularyInterpretation(
            id: candidateInterpretationID, occurrenceID: candidateOccurrence.id, senseID: otherSenseID,
            status: .candidate, meaning: "to call something back to mind", meaningLanguage: .english,
            meaningOrigin: .captured, translation: "回想", translationLanguage: .chinese,
            completeness: .sentence, createdAt: Date(timeIntervalSinceReferenceDate: 811_111_129.75)
        )
        var candidateWithExplanation = candidate
        candidateWithExplanation.explanations = [Self.explanation(
            id: id(333), input: candidateInput,
            createdAt: Date(timeIntervalSinceReferenceDate: 811_111_131.875)
        )]

        let targetSense = VocabularySense(
            id: targetSenseID, meaning: "bring something back to mind", meaningLanguage: nil,
            meaningOrigin: .user, standaloneMeanings: [
                .init(text: "记起", language: .chinese), .init(text: "想起", language: .chinese)
            ], alternateMeanings: [
                .init(text: "recollect", language: .english), .init(text: "", language: nil)
            ], mergedFrom: [mergedSenseID], createdAt: createdAt, updatedAt: updatedAt,
            createdWithoutContext: true
        )
        var targetEntry = VocabularyEntry(
            id: targetEntryID, expression: "remember", dictionaryForm: "remember", language: nil,
            kind: .word, senses: [targetSense], createdAt: createdAt, updatedAt: updatedAt
        )
        let targetGeneralInput = VocabularyExplanationIdentity.input(for: targetEntry, sense: targetSense, example: nil)
        targetEntry.senses[0].explanations = [Self.explanation(
            id: id(331), input: targetGeneralInput,
            createdAt: Date(timeIntervalSinceReferenceDate: 811_111_133.125)
        )]

        let otherSense = VocabularySense(
            id: otherSenseID, meaning: "call something back to mind", meaningLanguage: .english,
            meaningOrigin: .captured, createdAt: createdAt, updatedAt: updatedAt
        )
        let otherEntry = VocabularyEntry(
            id: otherEntryID, expression: "recall", dictionaryForm: "recall", language: .english,
            kind: .expression, senses: [otherSense], createdAt: createdAt, updatedAt: updatedAt
        )

        let currentReceipt = ReviewAudioReceipt(
            fingerprint: currentReceiptFingerprint, textHash: String(repeating: "e", count: 64),
            endpoint: "http://localhost:8765", profile: "private-profile-current", filename: currentReceiptFilename
        )
        let preservedReceipt = ReviewAudioReceipt(
            fingerprint: preservedReceiptFingerprint, textHash: String(repeating: "f", count: 64),
            endpoint: "http://localhost:8765", profile: "private-profile-preserved", filename: preservedReceiptFilename
        )
        let currentPlan = ReviewPlan(
            id: currentPlanID, name: "Current preparation", deck: "Notebook deck", answer: "Current answer",
            includeNotes: true, fieldOverrides: ["Back": "A local override"],
            audioKinds: [.expression], audioReceipts: [.expression: currentReceipt]
        )
        let preservedPlan = ReviewPlan(
            id: preservedPlanID, name: "Prior preparation", answer: "Preserved answer",
            audioKinds: [.sentence], audioReceipts: [.sentence: preservedReceipt]
        )

        let bindings: [AnkiNoteBinding]
        let activeBindingID: UUID?
        switch bindingScenario {
        case .multipleWithMergedActive:
            bindings = [
                Self.binding(id: currentBindingID, originSenseID: targetSenseID, noteID: 7101),
                Self.binding(id: mergedBindingID, originSenseID: mergedSenseID, noteID: 7102)
            ]
            activeBindingID = mergedBindingID
        case .singleWithoutActive:
            bindings = [Self.binding(id: currentBindingID, originSenseID: mergedSenseID, noteID: 7101)]
            activeBindingID = nil
        }
        let privateReview = VocabularyReview(
            plan: currentPlan, bindings: bindings, activeBindingID: activeBindingID,
            preservedPlans: [preservedPlan]
        )

        let reviewCardLayout = ReviewLayout(
            front: [ReviewCardPart(id: id(421), source: .expression)],
            back: [ReviewCardPart(
                id: id(422), source: .custom,
                content: [.init(id: id(423), content: .text(.init(text: "Card-only note", style: .paragraph, bold: true)))]
            )]
        )
        let reviewCard = VocabularyReview(plan: ReviewPlan(
            id: cardPlanID, name: "Flexible card", layout: reviewCardLayout,
            includeExplanation: true, includeSenseContent: false
        ))
        let collectionContent = [VocabularyContentBlock(
            id: id(431), content: .text(.init(text: "Personal study note", style: .heading, italic: true))
        )]
        let conceptID = id(501)
        let secondConceptID = id(502)
        let roleID = id(513)
        let slotID = id(522)
        let meaningNode = VocabularyMeaningNode(
            id: conceptID, kind: .concept,
            labels: [
                .init(id: id(511), text: "memory", language: .english),
                .init(id: id(512), text: "recuerdo", language: .spanish, preferred: false)
            ], definition: "A fact or experience available to be recalled.", scopeNote: "Long-term learning",
            roles: [.init(id: roleID, name: "rememberer", description: "The person who recalls it.")],
            provenance: .init(origin: .model, status: .confirmed, source: "fixture-model", confidence: 0.9),
            createdAt: createdAt, updatedAt: updatedAt
        )
        let relatedNode = VocabularyMeaningNode(
            id: secondConceptID, labels: [.init(id: id(514), text: "recollection", language: .english)],
            definition: "An act of recalling.", createdAt: createdAt, updatedAt: updatedAt
        )
        let pattern = VocabularyUsagePattern(
            id: id(521), senseID: targetSenseID, template: "someone remembers something",
            slots: [.init(id: slotID, name: "rememberer", constraint: "a person")],
            formality: .neutral, medium: .written, region: "general", note: "Stable pattern",
            collocations: ["remember a name", "remember a place"]
        )
        let mapping = VocabularyMeaningMapping(
            id: id(531), nodeID: conceptID, senseID: targetSenseID, patternID: pattern.id,
            relation: .expressesContent, conditions: "When a fact is recalled.", nuance: "Intentional or spontaneous.",
            roleBindings: [.init(id: id(532), roleID: roleID, slotID: slotID)],
            evidenceIDs: [acceptedInterpretationID]
        )
        let semantic = VocabularySemanticIndex(
            nodes: [relatedNode, meaningNode], patterns: [pattern], mappings: [mapping],
            relations: [.init(id: id(533), sourceID: conceptID, targetID: secondConceptID, kind: .related, note: "Related concept")],
            cues: [.init(id: id(541), text: "bring to mind", language: .english, kind: .paraphrase)],
            cueTargets: [.init(id: id(542), cueID: id(541), nodeID: conceptID, conditions: "Recall context")]
        )

        let frameworkID = id(551)
        let parentCategoryID = id(552)
        let childCategoryID = id(553)
        let classification = VocabularyClassificationIndex(
            frameworks: [.init(id: frameworkID, key: "fixture.concepts", version: 7)],
            categories: [
                .init(
                    id: childCategoryID, axis: .content,
                    labels: [.init(id: id(572), text: "Memory", language: .english)],
                    definition: "Encoding and recalling information.",
                    examples: [.init(text: "Recall a familiar route.", language: "en")],
                    scopeNote: "Includes both remembering and forgetting.",
                    references: [.init(
                        source: "Fixture taxonomy", identifier: "memory-7",
                        url: "https://example.test/taxonomy/memory", relationship: .adapted,
                        attribution: "Notebook test fixture", license: "CC0"
                    )],
                    localizations: [.init(language: "zh-Hans", name: "记忆", definition: "信息的保存与提取。")],
                    frameworkID: frameworkID, key: "memory"
                ),
                .init(
                    id: parentCategoryID, axis: .content,
                    labels: [.init(id: id(571), text: "Cognition", language: .english)],
                    definition: "Mental processes and knowledge.", frameworkID: frameworkID, key: "cognition",
                    provenance: .init(origin: .imported, status: .confirmed, source: "fixture-catalog")
                )
            ],
            parents: [.init(id: id(575), categoryID: childCategoryID, parentID: parentCategoryID)],
            memberships: [.init(id: id(574), nodeID: conceptID, categoryID: childCategoryID)],
            overrides: [.init(
                categoryID: childCategoryID,
                labels: [.init(id: id(573), text: "Remembering", language: .english)],
                definition: "A local definition for this test.", examples: [], isHidden: false
            )]
        )

        let template = ReviewLayoutTemplate(
            id: id(561), name: "Reusable template",
            layout: ReviewLayout(
                front: [ReviewCardPart(id: id(562), source: .expression)],
                back: [ReviewCardPart(id: id(563), source: .meaning)]
            )
        )
        var target = targetEntry, other = otherEntry
        target.senses[0].note = "Keep the evidence with this sense."
        target.senses[0].tags = ["review", "ordered"]
        target.senses[0].content = collectionContent
        target.senses[0].review = privateReview
        target.senses[0].reviewCards = [reviewCard]
        target.senses[0].savedAt = savedAt
        other.senses[0].note = "Candidate has no accepted reading."
        other.senses[0].tags = ["candidate"]
        other.senses[0].savedAt = Date(timeIntervalSinceReferenceDate: 811_111_139.25)
        let document = VocabularyDocument(
            catalog: [target, other], sources: [candidateSource, acceptedSource],
            occurrences: [candidateOccurrence, acceptedOccurrence],
            interpretations: [candidateWithExplanation, accepted],
            reviewTemplates: [template], semantics: semantic, classification: classification
        )
        try VocabularyDocumentValidation.validate(document)
        return document
    }

    static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", suffix))")!
    }

    private static func binding(id: UUID, originSenseID: UUID, noteID: Int64) -> AnkiNoteBinding {
        let identityField = ReviewField.identity.rawValue
        return .init(
            id: id, originSenseID: originSenseID, endpoint: "http://localhost:8765",
            profile: "private-profile-\(noteID)", noteID: noteID, model: "Private model",
            deck: "Private deck", identityField: identityField,
            mapping: [.identity: identityField, .expression: "Expression", .meaning: "Meaning"],
            fields: [identityField: originSenseID.uuidString.lowercased(), "Expression": "private note text"],
            syncedAt: Date(timeIntervalSinceReferenceDate: 811_111_143.5)
        )
    }

    private static func explanation(
        id: UUID, input: LearningExplanationInput, createdAt: Date
    ) -> LearningExplanationRecord {
        .init(
            id: id, input: input, language: .english,
            result: .init(meaning: "A concise meaning.", explanation: "A short learner-facing explanation."),
            model: "fixture-explainer", createdAt: createdAt
        )
    }
}

// Fixtures use this flattened view when a test already knows a sense's position.
extension VocabularyDocument {
    var savedSenses: [VocabularySense] {
        get { catalog.flatMap(\.senses) }
        set {
            let byID = Dictionary(uniqueKeysWithValues: newValue.map { ($0.id, $0) })
            for entry in catalog.indices {
                for index in catalog[entry].senses.indices {
                    let sense = catalog[entry].senses[index]
                    if let value = byID[sense.id] { catalog[entry].senses[index] = value }
                }
            }
        }
    }
}
