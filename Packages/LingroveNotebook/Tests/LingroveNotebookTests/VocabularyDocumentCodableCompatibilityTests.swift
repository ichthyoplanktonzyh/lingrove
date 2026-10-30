import Foundation
import Testing
import LingroveNotebook

/// These fixtures were encoded by the pre-extraction declarations frozen from `HEAD` under
/// `build/notebook-domain-baseline`, not by the package types under test. The round-trip test
/// therefore compares the new public module against an independent historical encoder.
struct VocabularyDocumentCodableCompatibilityTests {
    @Test func frozenVersionEightDocumentRetainsWireShapeAndRelationships() throws {
        let fixture = try Self.fixture("document-v8.json")
        let document = try JSONDecoder().decode(VocabularyDocument.self, from: fixture)

        #expect(document.schemaVersion == 8)
        #expect(document.catalog.count == 1)
        #expect(document.catalog[0].expression == "bank")
        #expect(document.catalog[0].senses.map(\.meaning) == [
            "a financial institution",
            "land alongside a river"
        ])
        #expect(document.catalog[0].senses.map(\.id.uuidString) == [
            "00000000-0000-4000-8000-000000000101",
            "00000000-0000-4000-8000-000000000102"
        ])

        #expect(document.interpretations.map(\.status) == [.accepted, .candidate, .rejected])
        #expect(document.interpretations[1].senseID == nil)
        #expect(document.sources.count == 1)
        #expect(document.occurrences.count == 2)
        #expect(document.occurrences.map(\.ranges).flatMap { $0 }.map(\.location) == [7, 62])
        #expect(document.occurrences.map(\.ranges).flatMap { $0 }.allSatisfy { $0.length == 4 })

        let source = try #require(document.sources.first)
        #expect(source.text.hasPrefix("🏦 "))
        for occurrence in document.occurrences {
            let range = try #require(Range(occurrence.ranges[0].nsRange, in: source.text))
            #expect(String(source.text[range]) == "bank")
        }

        let explanation = try #require(document.interpretations[0].explanations.first)
        #expect(explanation.id.uuidString == "00000000-0000-4000-8000-000000000401")
        #expect(explanation.language == .japanese)
        #expect(explanation.input.contextKind == .sentence)
        #expect(explanation.input.occurrenceIdentity == "occurrence-bank-finance")
        #expect(explanation.result.meaning == "お金を預けたり借りたりする金融機関。")

        let financeCollection = try #require(document.collections.first {
            $0.senseID.uuidString == "00000000-0000-4000-8000-000000000101"
        })
        let riverCollection = try #require(document.collections.first {
            $0.senseID.uuidString == "00000000-0000-4000-8000-000000000102"
        })
        #expect(financeCollection.interpretationIDs.map(\.uuidString) == [
            "00000000-0000-4000-8000-000000000301"
        ])
        #expect(!financeCollection.isSavedWithoutContext)
        #expect(riverCollection.interpretationIDs.isEmpty)
        #expect(riverCollection.isSavedWithoutContext)
        #expect(riverCollection.content?.isEmpty == true)
        #expect(riverCollection.review == nil)
        #expect(riverCollection.reviewCards?.isEmpty == true)

        let richContent = try #require(financeCollection.content)
        #expect(richContent.count == 2)
        guard case let .text(textContent) = richContent[0].content else {
            Issue.record("The first rich-content block should keep its text discriminator.")
            return
        }
        #expect(textContent.style == .heading)
        #expect(textContent.bold)
        guard case let .image(imageReference, caption) = richContent[1].content else {
            Issue.record("The second rich-content block should keep its image discriminator.")
            return
        }
        #expect(imageReference.digest == "0123456789abcdef")
        #expect(caption == "Downtown branch")

        let review = try #require(financeCollection.review)
        #expect(review.plan.audioKinds == [.expression])
        #expect(review.plan.audioReceipts?[.expression]?.filename == "bank-expression-fixture.mp3")
        #expect(review.preservedPlans.count == 1)
        #expect(review.preservedPlans[0].includeSenseContent == nil)
        #expect(review.preservedPlans[0].audioKinds == nil)
        #expect(review.preservedPlans[0].audioReceipts == nil)
        #expect(review.bindings.count == 1)
        #expect(review.activeBinding?.noteID == 24681012)
        #expect(review.activeBinding?.mapping[.expressionAudio] == "Audio")
        #expect(review.activeBinding?.fields["Front"] == "bank")

        #expect(document.semantics.nodes.count == 2)
        #expect(document.semantics.nodes[0].labels.map(\.text) == ["bank", "financial institution"])
        let mapping = try #require(document.semantics.mappings.first)
        #expect(mapping.senseID.uuidString == "00000000-0000-4000-8000-000000000101")
        #expect(mapping.patternID?.uuidString == "00000000-0000-4000-8000-000000000707")
        #expect(mapping.roleBindings.count == 1)
        #expect(mapping.evidenceIDs.map(\.uuidString) == [
            "00000000-0000-4000-8000-000000000301",
            "00000000-0000-4000-8000-000000000202"
        ])
        #expect(document.semantics.relations.first?.note == "Same written form, distinct senses.")
        #expect(document.semantics.cueTargets.first?.nodeID.uuidString == "00000000-0000-4000-8000-000000000705")

        let classification = document.classification
        #expect(classification.frameworks.first?.version == 3)
        #expect(classification.categories.first?.frameworkID?.uuidString == "00000000-0000-4000-8000-000000000711")
        #expect(classification.categories.first?.scopeNote == "Apply to the organization sense only.")
        #expect(classification.parents.first?.parentID.uuidString == "00000000-0000-4000-8000-000000000710")
        #expect(classification.memberships.first?.nodeID.uuidString == "00000000-0000-4000-8000-000000000705")
        #expect(classification.overrides.first?.labels?.isEmpty == true)
        #expect(classification.overrides.first?.examples == nil)
        #expect(classification.overrides.first?.references?.isEmpty == true)

        let reencoded = try JSONEncoder().encode(document)
        let historicalJSON = try JSONSerialization.jsonObject(with: fixture, options: [.fragmentsAllowed])
        let currentJSON = try JSONSerialization.jsonObject(with: reencoded, options: [.fragmentsAllowed])
        #expect(try Self.canonicalJSON(currentJSON) == Self.canonicalJSON(historicalJSON))
    }

    @Test func versionSevenAddsOnlyAnEmptyClassificationDirectoryAndPreservesAbsentOptionals() throws {
        let fixture = try Self.fixture("document-v7-missing-classification.json")
        let historicalJSON = try Self.jsonObject(fixture)
        #expect(historicalJSON["schemaVersion"] as? Int == 7)
        #expect(historicalJSON["classification"] == nil)
        #expect(historicalJSON["reviewTemplates"] == nil)

        let document = try JSONDecoder().decode(VocabularyDocument.self, from: fixture)
        #expect(document.schemaVersion == VocabularyDocument.currentVersion)
        #expect(document.classification.frameworks.isEmpty)
        #expect(document.classification.categories.isEmpty)
        #expect(document.classification.parents.isEmpty)
        #expect(document.classification.memberships.isEmpty)
        #expect(document.classification.overrides.isEmpty)
        #expect(document.reviewTemplates == nil)
        #expect(document.catalog[0].senses.map(\.id.uuidString) == [
            "00000000-0000-4000-8000-000000000101",
            "00000000-0000-4000-8000-000000000102"
        ])
        #expect(document.occurrences.count == 2)
        #expect(document.interpretations.map(\.status) == [.accepted, .candidate, .rejected])

        let upgraded = try Self.jsonObject(JSONEncoder().encode(document))
        #expect(upgraded["schemaVersion"] as? Int == 8)
        #expect(upgraded["reviewTemplates"] == nil)
        let classification = try #require(upgraded["classification"] as? [String: Any])
        #expect((classification["categories"] as? [Any])?.isEmpty == true)
    }

    @Test func categoryGuidanceFieldsDefaultWithoutChangingOptionalOrEmptyMeaning() throws {
        let fixture = try Self.fixture("category-guidance-absent.json")
        let historicalJSON = try Self.jsonObject(fixture)
        let historicalClassification = try #require(historicalJSON["classification"] as? [String: Any])
        let historicalCategories = try #require(historicalClassification["categories"] as? [[String: Any]])
        #expect(historicalCategories[0]["examples"] == nil)
        #expect(historicalCategories[0]["scopeNote"] == nil)
        #expect(historicalCategories[0]["frameworkID"] == nil)

        let document = try JSONDecoder().decode(VocabularyDocument.self, from: fixture)
        let category = try #require(document.classification.categories.first)
        #expect(category.definition.isEmpty)
        #expect(category.examples.isEmpty)
        #expect(category.scopeNote.isEmpty)
        #expect(category.references.isEmpty)
        #expect(category.localizations.isEmpty)
        #expect(category.frameworkID == nil)
        #expect(category.key == nil)
        #expect(!category.isRetired)
        #expect(category.provenance.origin == .user)
        #expect(category.provenance.status == .confirmed)
        #expect(category.provenance.confidence == nil)

        let explicitOverride = try #require(document.classification.overrides.first)
        #expect(explicitOverride.labels?.isEmpty == true)
        #expect(explicitOverride.definition == "")
        #expect(explicitOverride.examples == nil)
        #expect(explicitOverride.references?.isEmpty == true)

        let reencoded = try Self.jsonObject(JSONEncoder().encode(document))
        let classification = try #require(reencoded["classification"] as? [String: Any])
        let categories = try #require(classification["categories"] as? [[String: Any]])
        #expect((categories[0]["examples"] as? [Any])?.isEmpty == true)
        #expect(categories[0]["frameworkID"] == nil)
        #expect(categories[0]["key"] == nil)
        let overrides = try #require(classification["overrides"] as? [[String: Any]])
        #expect((overrides[0]["labels"] as? [Any])?.isEmpty == true)
        #expect((overrides[0]["references"] as? [Any])?.isEmpty == true)
        #expect(overrides[0]["examples"] == nil)
    }

    @Test func removingACollectionDoesNotDeleteCatalogOrUncollectedEvidence() throws {
        var document = try JSONDecoder().decode(VocabularyDocument.self, from: Self.fixture("document-v8.json"))
        let sourceIDs = document.sources.map(\.id)
        let occurrenceIDs = document.occurrences.map(\.id)
        let interpretationIDs = document.interpretations.map(\.id)

        let allEntries = VocabularyNotebookProjection.entries(document, collectedOnly: false)
        #expect(allEntries[0].senses.map(\.note) == ["Compare with the river sense.", ""])
        #expect(allEntries[0].senses[0].examples.map(\.id.uuidString) == [
            "00000000-0000-4000-8000-000000000301"
        ])
        #expect(allEntries[0].senses[1].examples.isEmpty)

        document.collections.removeAll { $0.senseID.uuidString == "00000000-0000-4000-8000-000000000102" }
        let collected = VocabularyNotebookProjection.entries(document, collectedOnly: true)
        #expect(collected.count == 1)
        #expect(collected[0].senses.map(\.id.uuidString) == ["00000000-0000-4000-8000-000000000101"])

        #expect(document.catalog[0].senses.map(\.id.uuidString) == [
            "00000000-0000-4000-8000-000000000101",
            "00000000-0000-4000-8000-000000000102"
        ])
        #expect(document.sources.map(\.id) == sourceIDs)
        #expect(document.occurrences.map(\.id) == occurrenceIDs)
        #expect(document.interpretations.map(\.id) == interpretationIDs)
        #expect(document.interpretations.first(where: { $0.status == .candidate })?.senseID == nil)
        #expect(document.interpretations.first(where: { $0.status == .rejected }) != nil)
    }

    @Test func publicConstructorsKeepDefaultsUUIDIdentityAndLanguageRawValues() throws {
        let firstBlock = VocabularyContentBlock(content: .text(VocabularyTextContent()))
        let secondBlock = VocabularyContentBlock(content: .text(VocabularyTextContent()))
        #expect(firstBlock.id != secondBlock.id)
        guard case let .text(defaultText) = firstBlock.content else {
            Issue.record("The default rich-content block should be text.")
            return
        }
        #expect(defaultText.text.isEmpty)
        #expect(defaultText.style == .paragraph)
        #expect(!defaultText.bold && !defaultText.italic)

        let firstPlan = ReviewPlan()
        let secondPlan = ReviewPlan()
        #expect(firstPlan.id != secondPlan.id)
        #expect(firstPlan.recognition)
        #expect(!firstPlan.gap)
        #expect(!firstPlan.includeNotes && !firstPlan.includeExplanation)
        #expect(firstPlan.includeSenseContent == nil)
        #expect(firstPlan.audioKinds == nil && firstPlan.audioReceipts == nil)
        #expect(ReviewLayout().front.isEmpty && ReviewLayout().back.isEmpty)

        let defaultCategory = VocabularyCategory(id: Self.fixedID("00000000-0000-4000-8000-000000000801"), axis: .content, labels: [])
        #expect(defaultCategory.definition.isEmpty)
        #expect(defaultCategory.examples.isEmpty)
        #expect(defaultCategory.scopeNote.isEmpty)
        #expect(defaultCategory.frameworkID == nil && defaultCategory.key == nil)
        #expect(!defaultCategory.isRetired)

        let document = VocabularyDocument()
        #expect(document.schemaVersion == VocabularyDocument.currentVersion)
        #expect(document.catalog.isEmpty && document.collections.isEmpty)
        #expect(document.reviewTemplates == nil)
        #expect(VocabularyBackup(document: document, images: [:]).version == 1)
        #expect(LearningLanguage.allCases.map(\.rawValue) == [
            "en", "es", "fr", "de", "it", "pt", "nl", "ru", "zh-Hans", "zh-Hant", "ja", "ko", "hi", "ar"
        ])
    }

    @Test func snapshotBackupAndUnsupportedVersionUseTheSharedPublicContracts() throws {
        let document = try JSONDecoder().decode(VocabularyDocument.self, from: Self.fixture("document-v8.json"))
        let snapshot = VocabularySnapshot(revision: 12, document: document)
        #expect(snapshot.revision == 12)
        #expect(snapshot.document == document)

        let backup = VocabularyBackup(document: document, images: ["image.png": Data([0x01, 0x02, 0xFF])])
        let backupData = try JSONEncoder().encode(backup)
        let decodedBackup = try JSONDecoder().decode(VocabularyBackup.self, from: backupData)
        #expect(decodedBackup.version == 1)
        #expect(decodedBackup.document == document)
        #expect(decodedBackup.images["image.png"] == Data([0x01, 0x02, 0xFF]))

        var unsupported = try Self.jsonObject(Self.fixture("document-v8.json"))
        unsupported["schemaVersion"] = 9
        let unsupportedData = try JSONSerialization.data(withJSONObject: unsupported)
        do {
            _ = try JSONDecoder().decode(VocabularyDocument.self, from: unsupportedData)
            Issue.record("A document from a newer schema version should be rejected.")
        } catch let error as VocabularyError {
            if case .unsupportedVersion = error {
                // The portable decoder retains the app's existing typed error boundary.
            } else {
                Issue.record("The unsupported version should use VocabularyError.unsupportedVersion.")
            }
        }
    }

    private static func fixture(_ name: String) throws -> Data {
        let filename = URL(fileURLWithPath: name)
        let url = try #require(
            Bundle.module.url(
                forResource: filename.deletingPathExtension().lastPathComponent,
                withExtension: filename.pathExtension,
                subdirectory: "Fixtures"
            ),
            "Missing test fixture \(name) in the packaged Fixtures resource directory."
        )
        return try Data(contentsOf: url)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
    }

    /// JSON dictionaries are unordered, but these three Codable fields are also represented by
    /// unordered Swift containers. Normalize only those fields; every domain array keeps its
    /// original sequence so changing entry, role, example or content order remains observable.
    private static func canonicalJSON(_ value: Any) throws -> String {
        let normalized = normalizeKnownUnorderedContainers(value)
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalizeKnownUnorderedContainers(_ value: Any) -> Any {
        if let values = value as? [Any] {
            return values.map(normalizeKnownUnorderedContainers)
        }
        guard var object = value as? [String: Any] else { return value }

        for key in Array(object.keys) {
            guard let child = object[key] else { continue }
            switch key {
            case "audioKinds":
                if let rawValues = child as? [String] {
                    object[key] = rawValues.sorted()
                } else {
                    object[key] = normalizeKnownUnorderedContainers(child)
                }
            case "audioReceipts", "mapping":
                guard let flattenedPairs = child as? [Any], flattenedPairs.count.isMultiple(of: 2) else {
                    object[key] = normalizeKnownUnorderedContainers(child)
                    continue
                }
                var pairs: [(String, Any)] = []
                for index in stride(from: 0, to: flattenedPairs.count, by: 2) {
                    guard let rawKey = flattenedPairs[index] as? String else {
                        pairs.removeAll()
                        break
                    }
                    pairs.append((rawKey, normalizeKnownUnorderedContainers(flattenedPairs[index + 1])))
                }
                guard pairs.count * 2 == flattenedPairs.count else {
                    object[key] = child
                    continue
                }
                var sortedPairs: [Any] = []
                for (rawKey, pairValue) in pairs.sorted(by: { $0.0 < $1.0 }) {
                    sortedPairs.append(rawKey)
                    sortedPairs.append(pairValue)
                }
                object[key] = sortedPairs
            default:
                object[key] = normalizeKnownUnorderedContainers(child)
            }
        }
        return object
    }

    private static func fixedID(_ rawValue: String) -> UUID {
        guard let id = UUID(uuidString: rawValue) else {
            fatalError("The test fixture contains an invalid fixed UUID: \(rawValue)")
        }
        return id
    }
}
