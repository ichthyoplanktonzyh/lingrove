import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import Testing
@testable import LingroveNotebookStorage

/// These tests keep the portable row codec honest at the persistence boundary. The SQLite
/// adapter owns physical columns; this suite checks that typed rows carry the same document
/// identities, order and nullable index values across a database-shaped reconstruction.
struct VocabularyPersistenceCodecTests {
    @Test func frozenSchema5RowsRoundTripThroughPublicCodecValues() throws {
        let directory = try VocabularyStorageTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try VocabularyStorageTestSupport.copiedSchema5Fixture(to: directory)
        let database = try VocabularySQLiteDatabase(url: url)
        defer { database.connection.close() }

        let historical = try database.read().document
        let encoded = try VocabularyPersistenceCodec.encode(historical)
        // Rebuild each value from exactly what a SQL adapter stores: trusted family/identity
        // columns, one opaque JSON payload, and every typed index column including NULLs.
        let reopenedRows = try encoded.rows.map { row in
            try VocabularyPersistenceRow(
                entity: row.entity,
                id: row.id,
                parentID: row.parentID,
                position: row.position,
                payload: row.encodedPayload(),
                indexValues: row.indexValues
            )
        }
        let reopened = try VocabularyPersistenceCodec.decode(.init(
            rows: reopenedRows,
            reviewTemplatesPresent: encoded.reviewTemplatesPresent
        ))

        #expect(reopened == historical)
        #expect(reopened.catalog.map(\.id) == historical.catalog.map(\.id))
        #expect(reopened.catalog.map { $0.senses.map(\.id) } == historical.catalog.map { $0.senses.map(\.id) })
        #expect(reopened.sources.map(\.id) == historical.sources.map(\.id))
        #expect(reopened.occurrences.map(\.id) == historical.occurrences.map(\.id))
        #expect(reopened.interpretations.map(\.id) == historical.interpretations.map(\.id))
    }

    @Test func frozenCoreGraphEmitsCurrentPersistenceFamilies() throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "document-v9-codec",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let bytes = try Data(contentsOf: fixtureURL)
        var document = try JSONDecoder().decode(VocabularyDocument.self, from: bytes)
        // This Core fixture preserves a historical parent edge whose parent category was not
        // included. Complete only the in-memory copy so codec validation sees a valid graph.
        document.classification.categories.append(VocabularyCategory(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000710")!,
            axis: .content,
            labels: [VocabularyMeaningLabel(
                id: UUID(uuidString: "75000000-0000-0000-0000-000000000001")!,
                text: "Financial activity",
                language: .english
            )],
            frameworkID: UUID(uuidString: "00000000-0000-4000-8000-000000000711")!,
            key: "finance"
        ))
        // The wire fixture also preserves an empty overlay label list, which is not valid for a
        // persisted override. Give the in-memory overlay one preferred local label.
        var classification = document.classification
        let overrideIndex = try #require(classification.overrides.firstIndex {
            $0.categoryID == UUID(uuidString: "00000000-0000-4000-8000-000000000709")!
        })
        classification.overrides[overrideIndex].labels = [VocabularyMeaningLabel(
            id: UUID(uuidString: "77000000-0000-0000-0000-000000000001")!,
            text: "Financial organization",
            language: .english
        )]
        document.classification = classification
        // Mapping 713 also carried occurrence 202 as evidence. Semantic mappings cite the
        // accepted example/claim identity (301), so drop that invalid occurrence reference.
        var semantics = document.semantics
        let mappingIndex = try #require(semantics.mappings.firstIndex {
            $0.id == UUID(uuidString: "00000000-0000-4000-8000-000000000713")!
        })
        semantics.mappings[mappingIndex].evidenceIDs = [UUID(uuidString: "00000000-0000-4000-8000-000000000301")!]
        document.semantics = semantics

        // Check the graph-specific guards first so a future fixture drift identifies its layer.
        try VocabularySemanticPolicy.validate(document.semantics, entries: document.entries)
        try VocabularyClassificationPolicy.validate(document.classification, nodes: document.semantics.nodes)
        let frozenRows = try VocabularyPersistenceCodec.encode(document)
        let initiallyEmitted = Set(frozenRows.rows.map { $0.entity.rawValue })
        let currentFamilies = Set(VocabularyPersistenceEntity.allCases.filter { $0 != .collectionInterpretations }.map(\.rawValue))
        let missingFromFrozenCore = currentFamilies.subtracting(initiallyEmitted)
        #expect(missingFromFrozenCore == ["sense_explanations", "templates"])

        // The frozen graph predates one independent sense explanation and has no review-layout
        // template. Add the two missing leaf examples inline so the golden document stays pristine.
        var entry = document.catalog[0]
        var sense = entry.senses[0]
        let explanationInput = VocabularyExplanationIdentity.input(for: entry, sense: sense, example: nil)
        sense.explanations = [LearningExplanationRecord(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
            input: explanationInput,
            language: .english,
            result: .init(meaning: "a prepared sense", explanation: "A local codec test explanation."),
            model: "frozen-fixture-test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        entry.senses[0] = sense
        document.catalog[0] = entry
        document.reviewTemplates = [ReviewLayoutTemplate(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000001")!,
            name: "Codec template",
            layout: ReviewLayout()
        )]

        let encoded = try VocabularyPersistenceCodec.encode(document)
        #expect(Set(encoded.rows.map { $0.entity.rawValue }) == currentFamilies)
        #expect(try VocabularyPersistenceCodec.decode(encoded) == document)
    }

    @Test func allPersistenceFamiliesHaveStableNamesAndIndexColumnOrder() {
        let expected: [String: [String]] = [
            "entries": ["lookup_key", "language", "expression"],
            "senses": ["meaning"],
            "sources": [],
            "occurrences": [],
            "usages": ["occurrence_id", "sense_id", "status"],
            "collections": ["sense_id"],
            "collection_interpretations": ["usage_id"],
            "sense_explanations": [],
            "usage_explanations": [],
            "blocks": [],
            "reviews": [],
            "bindings": [],
            "templates": [],
            "meaning_nodes": ["kind"],
            "meaning_labels": ["language", "text", "preferred"],
            "meaning_roles": ["name"],
            "usage_patterns": ["template"],
            "pattern_slots": ["name"],
            "meaning_mappings": ["meaning_id", "pattern_id", "relation"],
            "mapping_roles": ["role_id", "slot_id"],
            "mapping_evidence": ["usage_id"],
            "meaning_relations": ["target_id", "relation"],
            "retrieval_cues": ["language", "text"],
            "cue_targets": ["meaning_id"],
            "classification_frameworks": ["catalog_key"],
            "categories": ["framework_id", "catalog_key", "axis"],
            "category_parents": ["category_id", "parent_category_id"],
            "category_memberships": ["meaning_id", "category_id"],
            "category_overrides": []
        ]

        // Column order is part of the adapter contract because SQLite binds values positionally.
        // The explicit family list also makes a new persisted row shape a deliberate review point.
        #expect(VocabularyPersistenceEntity.allCases.count == 29)
        #expect(Set(VocabularyPersistenceEntity.allCases.map(\.rawValue)) == Set(expected.keys))
        for entity in VocabularyPersistenceEntity.allCases {
            #expect(entity.indexKeys.map(\.rawValue) == expected[entity.rawValue, default: []])
            #expect(Set(entity.indexKeys).count == entity.indexKeys.count)
        }
    }

    @Test func headerPreservesAbsentVersusExplicitlyEmptyReviewTemplates() throws {
        let absent = try VocabularyPersistenceCodec.encode(VocabularyDocument(reviewTemplates: nil))
        let empty = try VocabularyPersistenceCodec.encode(VocabularyDocument(reviewTemplates: []))

        #expect(absent.rows.isEmpty)
        #expect(empty.rows.isEmpty)
        #expect(!absent.reviewTemplatesPresent)
        #expect(empty.reviewTemplatesPresent)
        #expect(try VocabularyPersistenceCodec.decode(absent).reviewTemplates == nil)
        #expect(try VocabularyPersistenceCodec.decode(empty).reviewTemplates == [])
    }

    @Test func explicitNullIndexColumnIsDifferentFromMissingColumn() throws {
        let category = VocabularyCategory(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
            axis: .content,
            labels: [VocabularyMeaningLabel(
                id: UUID(uuidString: "76000000-0000-0000-0000-000000000001")!,
                text: "Custom category",
                language: .english
            )]
        )
        let document = VocabularyDocument(classification: .init(categories: [category]))
        let encoded = try VocabularyPersistenceCodec.encode(document)
        let categoryRow = try #require(encoded.rows.first { $0.entity == .categories })

        #expect(categoryRow.indexValues.keys.contains(.frameworkID))
        #expect(categoryRow.indexValue(.frameworkID) == nil)
        #expect(categoryRow.indexValues.keys.contains(.catalogKey))
        #expect(categoryRow.indexValue(.catalogKey) == nil)
        #expect(try VocabularyPersistenceCodec.decode(encoded) == document)

        var missingFrameworkColumn = categoryRow.indexValues
        missingFrameworkColumn.removeValue(forKey: .frameworkID)
        #expect(throws: VocabularyError.invalidArchive) {
            try VocabularyPersistenceRow(
                entity: categoryRow.entity,
                id: categoryRow.id,
                parentID: categoryRow.parentID,
                position: categoryRow.position,
                payload: categoryRow.encodedPayload(),
                indexValues: missingFrameworkColumn
            )
        }
    }

    @Test func decoderRejectsDuplicateOrphanGappedAndInconsistentRows() throws {
        let directory = try VocabularyStorageTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try VocabularyStorageTestSupport.copiedSchema5Fixture(to: directory)
        let database = try VocabularySQLiteDatabase(url: url)
        defer { database.connection.close() }

        let encoded = try VocabularyPersistenceCodec.encode(database.read().document)
        let first = try #require(encoded.rows.first)
        let duplicate = VocabularyPersistenceRows(
            rows: encoded.rows + [first],
            reviewTemplatesPresent: encoded.reviewTemplatesPresent
        )
        #expect(throws: VocabularyError.invalidArchive) { try duplicate.keyedRows() }
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decode(duplicate) }

        let withoutSources = VocabularyPersistenceRows(
            rows: encoded.rows.filter { $0.entity != .sources },
            reviewTemplatesPresent: encoded.reviewTemplatesPresent
        )
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decode(withoutSources) }

        let secondSource = try #require(encoded.rows.first { $0.entity == .sources && $0.position == 1 })
        let gappedSource = try VocabularyPersistenceRow(
            entity: secondSource.entity,
            id: secondSource.id,
            parentID: secondSource.parentID,
            position: secondSource.position + 1,
            payload: secondSource.encodedPayload(),
            indexValues: secondSource.indexValues
        )
        let gappedRows = VocabularyPersistenceRows(
            rows: encoded.rows.map { $0.key == gappedSource.key ? gappedSource : $0 },
            reviewTemplatesPresent: encoded.reviewTemplatesPresent
        )
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decode(gappedRows) }

        let entry = try #require(encoded.rows.first { $0.entity == .entries })
        var contradictoryIndexes = entry.indexValues
        contradictoryIndexes[.expression] = "payload says another expression"
        let contradictoryEntry = try VocabularyPersistenceRow(
            entity: entry.entity,
            id: entry.id,
            parentID: entry.parentID,
            position: entry.position,
            payload: entry.encodedPayload(),
            indexValues: contradictoryIndexes
        )
        let inconsistentRows = VocabularyPersistenceRows(
            rows: encoded.rows.map { $0.key == entry.key ? contradictoryEntry : $0 },
            reviewTemplatesPresent: encoded.reviewTemplatesPresent
        )
        #expect(throws: VocabularyError.invalidArchive) { try VocabularyPersistenceCodec.decode(inconsistentRows) }
    }

    @Test func rowEqualityUsesDecodedValuesRatherThanJSONKeyOrSetOrder() throws {
        let review = VocabularyReview(plan: ReviewPlan(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!,
            fieldOverrides: ["front": "one", "meaning": "two"],
            audioKinds: [.expression, .sentence]
        ))
        let sortedEncoder = JSONEncoder()
        sortedEncoder.outputFormatting = [.sortedKeys]
        let firstPayload = try sortedEncoder.encode(review)

        var object = try #require(try JSONSerialization.jsonObject(with: firstPayload) as? [String: Any])
        var plan = try #require(object["plan"] as? [String: Any])
        let audioKinds = try #require(plan["audioKinds"] as? [String])
        plan["audioKinds"] = Array(audioKinds.reversed())
        object["plan"] = plan
        #expect(Array(audioKinds.reversed()) != audioKinds)
        let reorderedSet = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let originalJSON = try #require(String(data: reorderedSet, encoding: .utf8))
        let orderedOverrides = #""front":"one","meaning":"two""#
        let reversedOverrides = #""meaning":"two","front":"one""#
        #expect(originalJSON.contains(orderedOverrides))
        let reorderedJSON = originalJSON.replacingOccurrences(
            of: orderedOverrides,
            with: reversedOverrides
        )
        #expect(reorderedJSON.contains(reversedOverrides))
        #expect(reorderedJSON != originalJSON)

        let first = try VocabularyPersistenceRow(
            entity: .reviews,
            id: "review-1",
            parentID: "collection-1",
            position: 0,
            payload: firstPayload
        )
        let reordered = try VocabularyPersistenceRow(
            entity: .reviews,
            id: "review-1",
            parentID: "collection-1",
            position: 0,
            payload: Data(reorderedJSON.utf8)
        )

        #expect(first == reordered)
    }
}
