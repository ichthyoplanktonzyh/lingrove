import Foundation
import LingroveNotebook
import LingroveTextRules
import Testing

/// Public-API boundary tests for the deterministic rules extracted from the app.
/// Test values flow into the same policies used by archive validation and editing;
/// these tests deliberately avoid `@testable` so the package's public contract stays usable.
struct VocabularyRulesTests {
    @Test func identityKeysRetainTheHistoricalNormalizedFramingAndDigest() {
        let expression = "  cafe\u{301} \n\tbank  "
        let key = VocabularyIdentityPolicy.entryKey(
            expression: expression,
            language: .english,
            kind: .expression
        )

        // Frozen from the implementation at checkpoint 6a9f8ae2, not calculated by the policy under test.
        #expect(key == "c302e3889aa1de404fce8cdc2de9f96b691c7b80c4225c33bc7f50ccf314ac64")
        #expect(key == VocabularyIdentityPolicy.entryKey(
            expression: "café bank",
            language: .english,
            kind: .expression
        ))

        let example = VocabularyExample(
            id: UUID(),
            text: "we saw 🐈",
            translation: "",
            ranges: [VocabularyTextRange(NSRange(location: 7, length: 2))],
            completeness: .unknown,
            meaning: "",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(VocabularyIdentityPolicy.exampleKey(example) ==
            "26b05d19cab596671603d23468bde5c339d7f143c87230c11848cf549dc79ebb")
        #expect(VocabularyIdentityPolicy.exampleKey(nil) == "no-context")
    }

    @Test func utf16RulesRejectPartialCharactersAndOverflowingRanges() {
        let decomposed = "e\u{301}"
        #expect(UTF16TextRangePolicy.isValid(NSRange(location: 0, length: 2), in: decomposed))
        #expect(!UTF16TextRangePolicy.isValid(NSRange(location: 0, length: 1), in: decomposed))

        let emoji = "🐈"
        #expect(UTF16TextRangePolicy.isValid(NSRange(location: 0, length: 2), in: emoji))
        #expect(!UTF16TextRangePolicy.isValid(NSRange(location: 0, length: 1), in: emoji))
        #expect(!UTF16TextRangePolicy.isValid(NSRange(location: Int.max, length: 1), in: emoji))
        #expect(!UTF16TextRangePolicy.isValid(NSRange(location: 1, length: Int.max), in: emoji))

        #expect(UnicodeTextSafety.isSafeToInsert("first line\nsecond line"))
        #expect(!UnicodeTextSafety.isSafeToInsert("interior\ttab"))
        #expect(!UnicodeTextSafety.isSafeToInsert("bad\u{FFFD}decode"))
    }

    @Test func explanationValidationKeepsByteBoundsControlSafetyAndUnknownStates() {
        let maximumContext = String(repeating: "x", count: VocabularyExplanationValidation.maximumContextBytes)
        let validInput = explanationInput(context: maximumContext, contextKind: .unknown)
        #expect(VocabularyExplanationValidation.isValid(validInput))

        let oversizedInput = explanationInput(context: maximumContext + "x", contextKind: .none)
        #expect(!VocabularyExplanationValidation.isValid(oversizedInput))

        let unknown = explanationInput(context: "x", contextKind: .unknown)
        let none = explanationInput(context: "x", contextKind: .none)
        #expect(unknown.contextKind != none.contextKind)
        #expect(unknown != none)
        #expect(VocabularyExplanationValidation.isValid(unknown))
        #expect(VocabularyExplanationValidation.isValid(none))

        #expect(VocabularyExplanationValidation.isValid(.init(
            meaning: "A short meaning",
            explanation: "First line.\nSecond line."
        )))
        #expect(!VocabularyExplanationValidation.isValid(.init(
            meaning: "A\u{0001}meaning",
            explanation: "Otherwise readable."
        )))
        #expect(!VocabularyExplanationValidation.isValid(.init(
            meaning: "A short meaning",
            explanation: "Broken \u{FFFD} text."
        )))
    }

    @Test func lifecycleRetainsUncollectedEvidenceAndRejectsDuplicateOrDanglingIDs() throws {
        let sourceID = UUID()
        let occurrenceID = UUID()
        let source = VocabularySourceSnapshot(
            id: sourceID,
            text: "source text",
            kind: .captured,
            appBundleIdentifier: nil,
            encounteredAt: Date(timeIntervalSince1970: 0)
        )
        let occurrence = VocabularySourceOccurrence(
            id: occurrenceID,
            sourceID: sourceID,
            ranges: [VocabularyTextRange(NSRange(location: 0, length: 6))]
        )

        let evidenceOnly = VocabularyDocument(
            catalog: [], sources: [source], occurrences: [occurrence], interpretations: [], collections: []
        )
        try VocabularyLifecyclePolicy.validate(evidenceOnly)

        let uncollectedClaim = VocabularyInterpretation(
            id: UUID(), occurrenceID: occurrenceID, status: .candidate,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let claimWithoutCollection = VocabularyDocument(
            catalog: [], sources: [source], occurrences: [occurrence],
            interpretations: [uncollectedClaim], collections: []
        )
        try VocabularyLifecyclePolicy.validate(claimWithoutCollection)

        var duplicateSourceID = evidenceOnly
        duplicateSourceID.sources.append(source)
        #expect(throws: VocabularyError.invalidArchive) {
            try VocabularyLifecyclePolicy.validate(duplicateSourceID)
        }

        var danglingOccurrence = evidenceOnly
        danglingOccurrence.occurrences[0] = .init(
            id: occurrenceID, sourceID: UUID(), ranges: occurrence.ranges
        )
        #expect(throws: VocabularyError.invalidArchive) {
            try VocabularyLifecyclePolicy.validate(danglingOccurrence)
        }
    }

    @Test func semanticValidationChecksSensePatternEvidenceAndHierarchyReferences() throws {
        let now = Date(timeIntervalSince1970: 0)
        let senseID = UUID()
        let otherSenseID = UUID()
        let example = VocabularyExample(
            id: UUID(), text: "She ran.", translation: "",
            ranges: [VocabularyTextRange(NSRange(location: 4, length: 3))],
            completeness: .sentence, meaning: "move quickly", createdAt: now
        )
        let sense = VocabularySense(id: senseID, meaning: "move quickly", examples: [example], createdAt: now, updatedAt: now)
        let otherSense = VocabularySense(id: otherSenseID, meaning: "operate", createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(
            id: UUID(), expression: "run", dictionaryForm: "run", language: .english,
            kind: .word, senses: [sense, otherSense], createdAt: now, updatedAt: now
        )

        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "move quickly", language: .english)])
        let otherNode = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "operate", language: .english)])
        let pattern = VocabularyUsagePattern(senseID: senseID, template: "Someone runs")
        let otherSensePattern = VocabularyUsagePattern(senseID: otherSenseID, template: "Something runs")
        let mapping = VocabularyMeaningMapping(
            nodeID: node.id, senseID: senseID, patternID: pattern.id, evidenceIDs: [example.id]
        )
        let valid = VocabularySemanticIndex(nodes: [node], patterns: [pattern], mappings: [mapping])
        try VocabularySemanticPolicy.validate(valid, entries: [entry])

        var crossSensePattern = valid
        crossSensePattern.patterns.append(otherSensePattern)
        crossSensePattern.mappings[0].patternID = otherSensePattern.id
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularySemanticPolicy.validate(crossSensePattern, entries: [entry])
        }

        var unknownEvidence = valid
        unknownEvidence.mappings[0].evidenceIDs = [UUID()]
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularySemanticPolicy.validate(unknownEvidence, entries: [entry])
        }

        var cycle = valid
        cycle.nodes.append(otherNode)
        cycle.relations = [
            .init(sourceID: node.id, targetID: otherNode.id, kind: .narrower),
            .init(sourceID: otherNode.id, targetID: node.id, kind: .narrower)
        ]
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularySemanticPolicy.validate(cycle, entries: [entry])
        }
    }

    @Test func semanticEditingPreservesPatternAndEvidenceRestrictions() {
        let example = VocabularyExample(
            id: UUID(), text: "She ran.", translation: "",
            ranges: [VocabularyTextRange(NSRange(location: 4, length: 3))],
            completeness: .sentence, meaning: "move quickly", createdAt: Date(timeIntervalSince1970: 0)
        )
        let sense = VocabularySense(id: UUID(), meaning: "move quickly", examples: [example],
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let oldNode = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "movement")], roles: [.init(name: "actor")])
        let newNode = VocabularyMeaningNode(id: UUID(), kind: .function, labels: [.init(text: "action")])
        let patternID = UUID()
        let mapping = VocabularyMeaningMapping(
            nodeID: oldNode.id, senseID: sense.id, patternID: patternID,
            conditions: "old condition", nuance: "old nuance",
            roleBindings: [.init(roleID: oldNode.roles[0].id, slotID: UUID())], evidenceIDs: [example.id]
        )

        let reclassified = VocabularySemanticEditingPolicy.classify(
            mapping, under: newNode, conditions: "new condition", nuance: "new nuance"
        )
        #expect(reclassified.nodeID == newNode.id)
        #expect(reclassified.relation == .realizesFunction)
        #expect(reclassified.senseID == mapping.senseID)
        #expect(reclassified.patternID == patternID)
        #expect(reclassified.evidenceIDs == [example.id])
        #expect(reclassified.roleBindings.isEmpty)
        #expect(reclassified.conditions == "new condition" && reclassified.nuance == "new nuance")

        #expect(VocabularySemanticEditingPolicy.example(for: mapping, sense: sense) == example)
        var patternOnly = mapping
        patternOnly.evidenceIDs = []
        #expect(VocabularySemanticEditingPolicy.example(for: patternOnly, sense: sense) == nil)
        patternOnly.patternID = nil
        #expect(VocabularySemanticEditingPolicy.example(for: patternOnly, sense: sense) == example)
    }

    @Test func classificationAllowsMultiParentDAGAndRejectsCyclesAndLocaleAliases() throws {
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "not available", language: .english)])
        let root = category("root")
        let left = category("left")
        let right = category("right")
        let leaf = category("leaf")
        let dag = VocabularyClassificationIndex(
            categories: [root, left, right, leaf],
            parents: [
                .init(id: UUID(), categoryID: left.id, parentID: root.id),
                .init(id: UUID(), categoryID: right.id, parentID: root.id),
                .init(id: UUID(), categoryID: leaf.id, parentID: left.id),
                .init(id: UUID(), categoryID: leaf.id, parentID: right.id)
            ],
            memberships: [.init(id: UUID(), nodeID: node.id, categoryID: leaf.id)]
        )
        try VocabularyClassificationPolicy.validate(dag, nodes: [node])
        #expect(VocabularyClassificationPolicy.descendants(of: root.id, in: dag) ==
            Set([root.id, left.id, right.id, leaf.id]))
        #expect(VocabularyClassificationPolicy.ancestors(of: leaf.id, in: dag) ==
            Set([root.id, left.id, right.id, leaf.id]))
        #expect(VocabularyClassificationPolicy.meaningIDs(in: root.id, index: dag) == [node.id])

        var cyclic = dag
        cyclic.parents.append(.init(id: UUID(), categoryID: root.id, parentID: leaf.id))
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyClassificationPolicy.validate(cyclic, nodes: [node])
        }

        var duplicateLocale = dag
        duplicateLocale.categories[3].localizations = [
            .init(language: "en_US", name: "Leaf"),
            .init(language: "en-us", definition: "A leaf category.")
        ]
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyClassificationPolicy.validate(duplicateLocale, nodes: [node])
        }

        let labels = [
            VocabularyMeaningLabel(text: "English", language: .english),
            VocabularyMeaningLabel(text: "繁體", language: .traditionalChinese)
        ]
        #expect(VocabularyMeaningLabelRules.language(for: "zh_Hant_TW") == .traditionalChinese)
        #expect(VocabularyMeaningLabelRules.label(in: labels, languages: [.traditionalChinese, .english])?.text == "繁體")
    }

    @Test func classificationOverridesDistinguishInheritedFieldsFromExplicitClears() throws {
        let reference = VocabularyCategoryReference(
            source: "Reference", identifier: "1", url: "https://example.test/1", relationship: .adapted
        )
        let base = VocabularyCategory(
            id: UUID(), axis: .content, labels: [.init(text: "Base", language: .english)],
            definition: "Base definition", examples: [.init(text: "Example")], scopeNote: "Keep this scope",
            references: [reference],
            localizations: [.init(language: "fr", name: "Nom", definition: "Définition", scopeNote: "Portée")]
        )
        let overlay = VocabularyCategoryOverride(
            categoryID: base.id, definition: "", examples: [], references: []
        )
        let index = VocabularyClassificationIndex(categories: [base], overrides: [overlay])
        try VocabularyClassificationPolicy.validate(index, nodes: [])

        let effective = VocabularyClassificationPolicy.effective(base, in: index)
        #expect(effective.labels == base.labels)
        #expect(effective.definition.isEmpty)
        #expect(effective.examples.isEmpty)
        #expect(effective.references.isEmpty)
        #expect(effective.scopeNote == "Keep this scope")
        #expect(effective.localizations == [
            .init(language: "fr", name: "Nom", definition: nil, scopeNote: "Portée")
        ])
    }

    @Test func contentValidationRejectsExcessCountAndExtremeImageByteCounts() {
        let tooManyBlocks = (0..<65).map { _ in
            VocabularyContentBlock(content: .text(.init(text: "content")))
        }
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyContentPolicy.validate(tooManyBlocks)
        }

        let extreme = VocabularyImageReference(
            digest: String(repeating: "a", count: 64), width: 1, height: 1, byteCount: Int.max
        )
        #expect(!VocabularyContentPolicy.valid(extreme))
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyContentPolicy.validate([.init(content: .image(extreme, caption: ""))])
        }

        let maximumImage = VocabularyImageReference(
            digest: String(repeating: "a", count: 64), width: 1, height: 1,
            byteCount: VocabularyContentPolicy.maximumImageBytes
        )
        let overSenseBudget = (0..<5).map { _ in
            VocabularyContentBlock(content: .image(maximumImage, caption: ""))
        }
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyContentPolicy.validate(overSenseBudget)
        }
    }

    private func explanationInput(context: String, contextKind: LearningExplanationContext) -> LearningExplanationInput {
        LearningExplanationInput(
            target: "target", dictionaryForm: "target", language: .english, kind: .word,
            context: context, ranges: [VocabularyTextRange(NSRange(location: 0, length: 1))],
            contextKind: contextKind
        )
    }

    private func category(_ label: String) -> VocabularyCategory {
        VocabularyCategory(id: UUID(), axis: .content, labels: [.init(text: label)])
    }
}
