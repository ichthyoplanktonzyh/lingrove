import Foundation
import Testing
import LingroveNotebook
import LingroveNotebookSync

/// These tests exercise the public transport seam as a complete domain graph. They prove the
/// mapper's strictness and privacy behavior without involving a store, account, or network client.
/// This suite owns contract-level assertions over the transport value boundary.
/// Each test builds its own value fixture and never shares mutable state across runs.
struct VocabularyWireProjectionCodecTests {
    @Test func inlineMarksRoundTripWithoutChangingPlainTextWireRecords() throws {
        var document = try VocabularyWireTestFixture.document()
        document.catalog[0].senses[0].content = [.init(content: .text(.init(text: "one two", runs: [.init(location: 4, length: 3, bold: true)])))]
        let projection = try VocabularyWireProjectionCodec.project(document, notebookID: VocabularyWireTestFixture.notebookID)
        let restored = try VocabularyWireProjectionCodec.materializeComplete(projection.entities,
            notebookID: VocabularyWireTestFixture.notebookID, preserving: projection.privateState)
        #expect(restored.document.catalog[0].senses[0].content == document.catalog[0].senses[0].content)
    }

    @Test("A strict-valid graph round-trips all wire entity families and ordering")
    func completeGraphRoundTripsInRankOrder() throws {
        let document = try VocabularyWireTestFixture.document()
        try VocabularyDocumentValidation.validate(document)

        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        #expect(Set(projection.entities.map(\.entityType)) == Set(VocabularyWireEntityKind.allCases))
        #expect(VocabularyWireEntityKind.allCases.count == 27)

        // Exercise Codable as well as the mapper. A server may return rows in any physical order;
        // domain arrays are rebuilt from their explicit rank fields.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(projection.entities)
        let decoded = try JSONDecoder().decode([VocabularyWireEntity].self, from: encoded)
        let materialized = try VocabularyWireProjectionCodec.materializeComplete(
            Array(decoded.reversed()), notebookID: VocabularyWireTestFixture.notebookID,
            preserving: projection.privateState
        )

        #expect(materialized.document == document)
        #expect(materialized.document.catalog.map(\.id) == document.catalog.map(\.id))
        #expect(materialized.document.sources.map(\.id) == document.sources.map(\.id))
        #expect(materialized.document.occurrences.map(\.id) == document.occurrences.map(\.id))
        #expect(materialized.document.interpretations.map(\.id) == document.interpretations.map(\.id))
        #expect(materialized.document.savedSenses.map(\.id) == document.savedSenses.map(\.id))
        #expect(materialized.document.semantics.nodes.map(\.id) == document.semantics.nodes.map(\.id))
        #expect(materialized.document.classification.categories.map(\.id) == document.classification.categories.map(\.id))
        #expect(materialized.document.catalog[0].createdAt.timeIntervalSinceReferenceDate == 811_111_111.125)
        #expect(materialized.document.sources[1].encounteredAt.timeIntervalSinceReferenceDate == 811_111_119.1234567)
        #expect(materialized.document.catalog[0].language == nil)
        #expect(materialized.document.catalog[0].senses[0].meaningLanguage == nil)
        #expect(materialized.unattachedPrivateState.reviews.isEmpty)
        #expect(materialized.unattachedPrivateState.explanations.isEmpty)
    }

    @Test("Nil and empty optional collections retain distinct wire presence")
    func nilAndEmptyPresenceRoundTrips() throws {
        var nilDocument = try VocabularyWireTestFixture.document()
        nilDocument.reviewTemplates = nil
        nilDocument.savedSenses[1].content = nil
        nilDocument.savedSenses[1].reviewCards = nil

        var emptyDocument = nilDocument
        emptyDocument.reviewTemplates = []
        emptyDocument.savedSenses[1].content = []
        emptyDocument.savedSenses[1].reviewCards = []
        try VocabularyDocumentValidation.validate(nilDocument)
        try VocabularyDocumentValidation.validate(emptyDocument)

        for candidate in [nilDocument, emptyDocument] {
            let projection = try VocabularyWireProjectionCodec.project(
                candidate, notebookID: VocabularyWireTestFixture.notebookID
            )
            let result = try VocabularyWireProjectionCodec.materializeComplete(
                projection.entities, notebookID: VocabularyWireTestFixture.notebookID,
                preserving: projection.privateState
            )
            #expect(result.document == candidate)
        }
    }

    @Test("Nonfinite public timestamps are rejected before producing wire entities")
    func nonfinitePublicDatesAreRejected() throws {
        let baseline = try VocabularyWireTestFixture.document()
        var invalidEntry = baseline
        invalidEntry.catalog[0].updatedAt = Date(timeIntervalSinceReferenceDate: .infinity)

        var invalidSense = baseline
        invalidSense.catalog[0].senses[0].updatedAt = Date(timeIntervalSinceReferenceDate: -.infinity)

        var invalidCollection = baseline
        invalidCollection.savedSenses[0].savedAt = Date(timeIntervalSinceReferenceDate: .infinity)

        var invalidExplanation = baseline
        let originalExplanation = invalidExplanation.catalog[0].senses[0].explanations[0]
        invalidExplanation.catalog[0].senses[0].explanations[0] = .init(
            id: originalExplanation.id, input: originalExplanation.input, language: originalExplanation.language,
            result: originalExplanation.result, model: originalExplanation.model,
            createdAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )

        var invalidSemantic = baseline
        invalidSemantic.semantics.nodes[0].createdAt = Date(timeIntervalSinceReferenceDate: .infinity)

        for candidate in [invalidEntry, invalidSense, invalidCollection, invalidExplanation, invalidSemantic] {
            #expect(throws: VocabularyWireError.invalidDocument) {
                _ = try VocabularyWireProjectionCodec.project(
                    candidate, notebookID: VocabularyWireTestFixture.notebookID
                )
            }
        }
    }

    @Test("Private Anki fields, audio receipts, and explanation identity stay off public wire")
    func publicEntitiesExcludePrivateOverlayFields() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        let bytes = try JSONEncoder().encode(projection.entities)
        let json = try #require(String(data: bytes, encoding: .utf8))

        #expect(!json.contains("http://localhost:8765"))
        #expect(!json.contains("private-profile"))
        #expect(!json.contains("Private model"))
        #expect(!json.contains("Private deck"))
        #expect(!json.contains("private note text"))
        #expect(!json.contains(VocabularyWireTestFixture.currentReceiptFingerprint))
        #expect(!json.contains(VocabularyWireTestFixture.preservedReceiptFingerprint))
        #expect(!json.contains(VocabularyWireTestFixture.currentReceiptFilename))
        #expect(!json.contains(VocabularyWireTestFixture.preservedReceiptFilename))
        #expect(!json.contains("occurrenceIdentity"))

        let localReview = try #require(projection.privateState.reviews.first)
        #expect(localReview.bindings.map(\.id) == [
            VocabularyWireTestFixture.currentBindingID,
            VocabularyWireTestFixture.mergedBindingID
        ])
        #expect(Set(localReview.audio.map(\.planID)) == Set([
            VocabularyWireTestFixture.currentPlanID,
            VocabularyWireTestFixture.preservedPlanID
        ]))
        #expect(projection.privateState.explanations.contains {
            $0.occurrenceIdentity == "local-only:candidate-explanation"
        })
    }

    @Test("Explanation occurrence identities are rebuilt or restored from local state")
    func explanationIdentityIsLocalAndStable() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        let result = try VocabularyWireProjectionCodec.materializeComplete(
            projection.entities, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: projection.privateState
        )

        let targetEntry = try #require(result.document.catalog.first {
            $0.id == VocabularyWireTestFixture.targetEntryID
        })
        let targetSense = try #require(targetEntry.senses.first)
        #expect(targetSense.explanations.first?.input.occurrenceIdentity == "sense:\(targetSense.id.uuidString)")

        let accepted = try #require(result.document.interpretations.first {
            $0.id == VocabularyWireTestFixture.acceptedInterpretationID
        })
        let example = try #require(result.document.entries.first {
            $0.id == VocabularyWireTestFixture.targetEntryID
        }?.senses.first?.examples.first {
            $0.id == VocabularyWireTestFixture.acceptedInterpretationID
        })
        #expect(accepted.explanations.first?.input.occurrenceIdentity == VocabularyIdentityPolicy.exampleKey(example))

        let candidate = try #require(result.document.interpretations.first {
            $0.id == VocabularyWireTestFixture.candidateInterpretationID
        })
        #expect(candidate.explanations.first?.input.occurrenceIdentity == "local-only:candidate-explanation")

        // Explanation IDs are owner-scoped in the core archive. A repeated ID inside one owner
        // cannot be represented by the composite wire entity key, while another owner may reuse it.
        var duplicateOwner = try VocabularyWireTestFixture.document()
        let repeated = try #require(duplicateOwner.catalog[0].senses[0].explanations.first)
        duplicateOwner.catalog[0].senses[0].explanations.append(repeated)
        try VocabularyDocumentValidation.validate(duplicateOwner)
        #expect(throws: VocabularyWireError.duplicateEntity) {
            _ = try VocabularyWireProjectionCodec.project(
                duplicateOwner, notebookID: VocabularyWireTestFixture.notebookID
            )
        }

        var crossOwner = try VocabularyWireTestFixture.document()
        let senseExplanation = try #require(crossOwner.catalog[0].senses[0].explanations.first)
        let candidateIndex = try #require(crossOwner.interpretations.firstIndex {
            $0.id == VocabularyWireTestFixture.candidateInterpretationID
        })
        var candidateClaim = crossOwner.interpretations[candidateIndex]
        let candidateExplanation = try #require(candidateClaim.explanations.first)
        candidateClaim.explanations[0] = .init(
            id: senseExplanation.id, input: candidateExplanation.input, language: candidateExplanation.language,
            result: candidateExplanation.result, model: candidateExplanation.model,
            createdAt: candidateExplanation.createdAt
        )
        crossOwner.interpretations[candidateIndex] = candidateClaim
        try VocabularyDocumentValidation.validate(crossOwner)
        let crossOwnerProjection = try VocabularyWireProjectionCodec.project(
            crossOwner, notebookID: VocabularyWireTestFixture.notebookID
        )
        let reusedExplanationID = senseExplanation.id.uuidString.lowercased()
        #expect(crossOwnerProjection.entities.contains {
            $0.entityType == .senseExplanation && $0.entityID == "\(VocabularyWireTestFixture.targetSenseID.uuidString.lowercased()):\(reusedExplanationID)"
        })
        #expect(crossOwnerProjection.entities.contains {
            $0.entityType == .interpretationExplanation && $0.entityID == "\(VocabularyWireTestFixture.candidateInterpretationID.uuidString.lowercased()):\(reusedExplanationID)"
        })
        let crossOwnerResult = try VocabularyWireProjectionCodec.materializeComplete(
            crossOwnerProjection.entities, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: crossOwnerProjection.privateState
        )
        #expect(crossOwnerResult.document == crossOwner)
    }

    @Test("An accepted explanation gets identity from current evidence")
    func acceptedExplanationUsesDerivedIdentity() throws {
        let document = try VocabularyWireTestFixture.document()
        try VocabularyDocumentValidation.validate(document)

        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        let capturedExplanation = try #require(projection.privateState.explanations.first {
            $0.ownerKind == .interpretationExplanation &&
                $0.ownerID == VocabularyWireTestFixture.acceptedInterpretationID
        })
        // This simulates an older local receipt whose input is still current but whose
        // occurrence key predates evidence reclassification on another client.
        let staleLocalExplanation = VocabularyWirePrivateState.Explanation(
            ownerKind: capturedExplanation.ownerKind, ownerID: capturedExplanation.ownerID,
            explanationID: capturedExplanation.explanationID, inputSignature: capturedExplanation.inputSignature,
            occurrenceIdentity: "old-local:accepted-key"
        )
        let localStateWithPriorKey = VocabularyWirePrivateState(
            notebookID: VocabularyWireTestFixture.notebookID,
            reviews: projection.privateState.reviews,
            explanations: projection.privateState.explanations + [staleLocalExplanation]
        )
        let changedSourceKind = projection.entities.map { entity in
            guard entity.entityType == .source,
                  entity.entityID == VocabularyWireTestFixture.id(301).uuidString.lowercased() else { return entity }
            var fields = entity.fields
            fields["kind"] = .string(VocabularyExample.SourceKind.imported.rawValue)
            return .init(entityType: entity.entityType, entityID: entity.entityID, fields: fields)
        }
        let result = try VocabularyWireProjectionCodec.materializeComplete(
            changedSourceKind, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: localStateWithPriorKey
        )
        let currentSource = try #require(result.document.sources.first {
            $0.id == VocabularyWireTestFixture.id(301)
        })
        #expect(currentSource.kind == .imported)
        let currentExample = try #require(result.document.entries.first {
            $0.id == VocabularyWireTestFixture.targetEntryID
        }?.senses.first?.examples.first {
            $0.id == VocabularyWireTestFixture.acceptedInterpretationID
        })
        #expect(currentExample.sourceKind == .imported)
        let currentClaim = try #require(result.document.interpretations.first {
            $0.id == VocabularyWireTestFixture.acceptedInterpretationID
        })
        #expect(currentClaim.explanations.first?.input.occurrenceIdentity == VocabularyIdentityPolicy.exampleKey(currentExample))
        #expect(currentClaim.explanations.first?.input.occurrenceIdentity != "old-local:accepted-key")
        #expect(result.unattachedPrivateState.explanations.isEmpty)
    }

    @Test("Complete windows reject a missing root, unknown field, and duplicate identity")
    func strictWindowRejectsMissingUnknownAndDuplicateRows() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )

        let missingRoot = projection.entities.filter { $0.entityType != .notebookSettings }
        #expect(throws: VocabularyWireError.incompleteSnapshot) {
            _ = try VocabularyWireProjectionCodec.materializeComplete(
                missingRoot, notebookID: VocabularyWireTestFixture.notebookID
            )
        }

        var unknownField = projection.entities
        let entryIndex = try #require(unknownField.firstIndex { $0.entityType == .entry })
        var fields = unknownField[entryIndex].fields
        fields["futureField"] = .string("must fail closed")
        unknownField[entryIndex] = .init(
            entityType: unknownField[entryIndex].entityType,
            entityID: unknownField[entryIndex].entityID,
            fields: fields
        )
        #expect(throws: VocabularyWireError.invalidRecord) {
            _ = try VocabularyWireProjectionCodec.materializeComplete(
                unknownField, notebookID: VocabularyWireTestFixture.notebookID
            )
        }

        #expect(throws: VocabularyWireError.duplicateEntity) {
            _ = try VocabularyWireProjectionCodec.materializeComplete(
                projection.entities + [projection.entities[0]], notebookID: VocabularyWireTestFixture.notebookID
            )
        }

        let entryEntity = try #require(projection.entities.first { $0.entityType == .entry })
        var rawEntity = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entryEntity)) as? [String: Any])
        rawEntity["serverMetadata"] = ["revision": "private server value"]
        let extendedEntity = try JSONSerialization.data(withJSONObject: rawEntity, options: [.sortedKeys])
        #expect(throws: VocabularyWireError.invalidRecord) {
            _ = try JSONDecoder().decode(VocabularyWireEntity.self, from: extendedEntity)
        }
    }

    @Test("Notebook identity and local private state are scope checked")
    func notebookAndPrivateScopesMustMatch() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        let otherNotebook = VocabularyWireTestFixture.id(9001)

        #expect(throws: VocabularyWireError.notebookMismatch) {
            _ = try VocabularyWireProjectionCodec.materializeComplete(
                projection.entities, notebookID: otherNotebook
            )
        }
        let wronglyScopedState = VocabularyWirePrivateState(notebookID: otherNotebook)
        #expect(throws: VocabularyWireError.privateScopeMismatch) {
            _ = try VocabularyWireProjectionCodec.materializeComplete(
                projection.entities, notebookID: VocabularyWireTestFixture.notebookID,
                preserving: wronglyScopedState
            )
        }
        #expect(throws: VocabularyWireError.privateScopeMismatch) {
            _ = try VocabularyWireProjectionCodec.project(
                document, notebookID: VocabularyWireTestFixture.notebookID,
                retaining: wronglyScopedState
            )
        }
    }

    @Test("Dangling graph references invalidate a complete window")
    func orphanedReferencesFailStrictMaterialization() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        let orphaned = projection.entities.filter {
            !($0.entityType == .category && $0.entityID == VocabularyWireTestFixture.id(553).uuidString.lowercased())
        }

        #expect(throws: VocabularyWireError.invalidDocument) {
            _ = try VocabularyWireProjectionCodec.materializeComplete(
                orphaned, notebookID: VocabularyWireTestFixture.notebookID,
                preserving: projection.privateState
            )
        }
    }

    @Test("Deleting a plan returns its bindings and audio receipts as unattached state")
    func deletedPlanLeavesPrivateStateUnattached() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        let withoutLegacyPlan = projection.entities.filter {
            !($0.entityType == .reviewDraft && $0.entityID == VocabularyWireTestFixture.legacyDraftID)
        }
        let materialized = try VocabularyWireProjectionCodec.materializeComplete(
            withoutLegacyPlan, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: projection.privateState
        )
        let collection = try #require(materialized.document.savedSenses.first {
            $0.id == VocabularyWireTestFixture.targetSenseID
        })
        #expect(collection.review == nil)
        let residue = try #require(materialized.unattachedPrivateState.reviews.first)
        #expect(residue.bindings.map(\.id) == [
            VocabularyWireTestFixture.currentBindingID,
            VocabularyWireTestFixture.mergedBindingID
        ])
        #expect(residue.audio.count == 2)

        let reprojected = try VocabularyWireProjectionCodec.project(
            materialized.document, notebookID: VocabularyWireTestFixture.notebookID,
            retaining: materialized.unattachedPrivateState
        )
        let repeated = try VocabularyWireProjectionCodec.materializeComplete(
            withoutLegacyPlan, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: reprojected.privateState
        )
        #expect(repeated.document == materialized.document)
        #expect(repeated.unattachedPrivateState.reviews == reprojected.privateState.reviews)
    }

    @Test("A changed plan leaves only its receipt unattached across repeated projection")
    func changedPlanRetainsBindingsAndActiveChoice() throws {
        for scenario in [
            VocabularyWireTestFixture.BindingScenario.multipleWithMergedActive,
            .singleWithoutActive
        ] {
            let document = try VocabularyWireTestFixture.document(bindingScenario: scenario)
            let projection = try VocabularyWireProjectionCodec.project(
                document, notebookID: VocabularyWireTestFixture.notebookID
            )
            let editedRemote = Self.changeLegacyPlanAnswer(in: projection.entities)
            let first = try VocabularyWireProjectionCodec.materializeComplete(
                editedRemote, notebookID: VocabularyWireTestFixture.notebookID,
                preserving: projection.privateState
            )
            let firstReview = try #require(first.document.savedSenses.first {
                $0.id == VocabularyWireTestFixture.targetSenseID
            }?.review)
            let originalReview = try #require(document.savedSenses.first {
                $0.id == VocabularyWireTestFixture.targetSenseID
            }?.review)
            #expect(firstReview.bindings == originalReview.bindings)
            #expect(firstReview.activeBindingID == originalReview.activeBindingID)
            #expect(firstReview.plan.answer == "Answer updated by the server")

            let residue = try #require(first.unattachedPrivateState.reviews.first)
            #expect(residue.bindings.isEmpty)
            #expect(residue.activeBindingID == nil)
            #expect(residue.audio.map(\.planID) == [VocabularyWireTestFixture.currentPlanID])

            let secondProjection = try VocabularyWireProjectionCodec.project(
                first.document, notebookID: VocabularyWireTestFixture.notebookID,
                retaining: first.unattachedPrivateState
            )
            #expect(secondProjection.privateState.reviews.count == 2)
            let second = try VocabularyWireProjectionCodec.materializeComplete(
                editedRemote, notebookID: VocabularyWireTestFixture.notebookID,
                preserving: secondProjection.privateState
            )
            let secondReview = try #require(second.document.savedSenses.first {
                $0.id == VocabularyWireTestFixture.targetSenseID
            }?.review)
            #expect(secondReview.bindings == originalReview.bindings)
            #expect(secondReview.activeBindingID == originalReview.activeBindingID)
            #expect(secondReview.plan.audioReceipts == nil)
            #expect(secondReview.preservedPlans.first?.audioReceipts != nil)
            #expect(second.unattachedPrivateState.reviews.first?.audio.map(\.planID) == [
                VocabularyWireTestFixture.currentPlanID
            ])
        }
    }

    @Test("Merged private bindings keep origin IDs and only restore a shared explicit selection")
    func mergedBindingOriginsAndActiveSelectionAreConservative() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(
            document, notebookID: VocabularyWireTestFixture.notebookID
        )
        let privateReview = try #require(projection.privateState.reviews.first)
        let firstBinding = try #require(privateReview.bindings.first)
        let mergedBinding = try #require(privateReview.bindings.last)
        #expect(mergedBinding.originSenseID == VocabularyWireTestFixture.mergedSenseID)

        func localReview(bindings: [AnkiNoteBinding], active: UUID?) -> VocabularyWirePrivateState.Review {
            .init(
                senseID: VocabularyWireTestFixture.targetSenseID, role: .legacy,
                bindings: bindings, activeBindingID: active, audio: []
            )
        }
        let twoExplicitAgree = VocabularyWirePrivateState(
            notebookID: VocabularyWireTestFixture.notebookID,
            reviews: [
                localReview(bindings: [firstBinding, mergedBinding], active: mergedBinding.id),
                localReview(bindings: [firstBinding, mergedBinding], active: mergedBinding.id)
            ], explanations: projection.privateState.explanations
        )
        let agreeingResult = try VocabularyWireProjectionCodec.materializeComplete(
            projection.entities, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: twoExplicitAgree
        )
        let agreeingReview = try #require(agreeingResult.document.savedSenses.first {
            $0.id == VocabularyWireTestFixture.targetSenseID
        }?.review)
        #expect(agreeingReview.bindings.map(\.id) == [firstBinding.id, mergedBinding.id])
        #expect(agreeingReview.activeBindingID == mergedBinding.id)

        let conflicting = VocabularyWirePrivateState(
            notebookID: VocabularyWireTestFixture.notebookID,
            reviews: [
                localReview(bindings: [firstBinding], active: firstBinding.id),
                localReview(bindings: [mergedBinding], active: mergedBinding.id)
            ], explanations: projection.privateState.explanations
        )
        let conflictingResult = try VocabularyWireProjectionCodec.materializeComplete(
            projection.entities, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: conflicting
        )
        let conflictingReview = try #require(conflictingResult.document.savedSenses.first {
            $0.id == VocabularyWireTestFixture.targetSenseID
        }?.review)
        #expect(conflictingReview.bindings.map(\.id) == [firstBinding.id, mergedBinding.id])
        #expect(conflictingReview.activeBindingID == nil)

        let nilAndExplicit = VocabularyWirePrivateState(
            notebookID: VocabularyWireTestFixture.notebookID,
            reviews: [
                localReview(bindings: [firstBinding], active: nil),
                localReview(bindings: [mergedBinding], active: mergedBinding.id)
            ], explanations: projection.privateState.explanations
        )
        let nilAndExplicitResult = try VocabularyWireProjectionCodec.materializeComplete(
            projection.entities, notebookID: VocabularyWireTestFixture.notebookID,
            preserving: nilAndExplicit
        )
        let nilAndExplicitReview = try #require(nilAndExplicitResult.document.savedSenses.first {
            $0.id == VocabularyWireTestFixture.targetSenseID
        }?.review)
        #expect(nilAndExplicitReview.activeBindingID == nil)
    }

    /// The external validator uses this one explicitly selected test in two processes. It
    /// exchanges only public entity JSON; each Swift invocation builds the private overlay locally.
    @Test(
        "nativeWireInteropBridge",
        .enabled(if: ProcessInfo.processInfo.environment["LINGROVE_NOTEBOOK_NATIVE_WIRE_MODE"] != nil)
    )
    func nativeWireInteropBridge() throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = try #require(environment["LINGROVE_NOTEBOOK_NATIVE_WIRE_MODE"])
        let bookText = try #require(environment["LINGROVE_NOTEBOOK_NATIVE_WIRE_BOOK_ID"])
        let notebookID = try #require(UUID(uuidString: bookText))
        #expect(bookText == notebookID.uuidString.lowercased())
        let document = try VocabularyWireTestFixture.document()

        switch mode {
        case "export":
            let path = try #require(environment["LINGROVE_NOTEBOOK_NATIVE_WIRE_EXPORT_PATH"])
            let projection = try VocabularyWireProjectionCodec.project(document, notebookID: notebookID)
            let envelope = NativeWireFixtureEnvelope(
                notebookId: notebookID.uuidString.lowercased(), entities: projection.entities
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let destination = Self.fileURL(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(envelope).write(to: destination, options: .atomic)
            #expect(FileManager.default.fileExists(atPath: destination.path))

        case "verify":
            let path = try #require(environment["LINGROVE_NOTEBOOK_NATIVE_WIRE_REMOTE_PATH"])
            let data = try Data(contentsOf: Self.fileURL(path))
            let remoteEntities = try JSONDecoder().decode([VocabularyWireEntity].self, from: data)
            let localState = try VocabularyWireProjectionCodec.project(document, notebookID: notebookID).privateState
            let materialized = try VocabularyWireProjectionCodec.materializeComplete(
                remoteEntities, notebookID: notebookID, preserving: localState
            )
            #expect(materialized.document == document)
            #expect(materialized.unattachedPrivateState.reviews.isEmpty)
            #expect(materialized.unattachedPrivateState.explanations.isEmpty)

        default:
            Issue.record("LINGROVE_NOTEBOOK_NATIVE_WIRE_MODE must be 'export' or 'verify'.")
        }
    }

    private static func changeLegacyPlanAnswer(in entities: [VocabularyWireEntity]) -> [VocabularyWireEntity] {
        entities.map { entity in
            guard entity.entityType == .reviewDraft,
                  entity.entityID == VocabularyWireTestFixture.legacyDraftID,
                  let planValue = entity.fields["plan"],
                  case let .object(existingPlan) = planValue else { return entity }
            var plan = existingPlan
            plan["answer"] = .string("Answer updated by the server")
            var fields = entity.fields
            fields["plan"] = .object(plan)
            return .init(entityType: entity.entityType, entityID: entity.entityID, fields: fields)
        }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
    }
}

/// The optional Postgres bridge receives only the canonical book ID and public entities.
/// Private bindings and receipts are deliberately not members of this export shape.
private struct NativeWireFixtureEnvelope: Codable {
    let notebookId: String
    let entities: [VocabularyWireEntity]
}
