import Foundation
import LingroveNotebook
import XCTest
@testable import LingroveNotebookEngine

/// These tests cross saved notebook snapshots, the enrollment facade, CardStore, review
/// admission, and a real SQLite file. They protect the boundary between corpus ownership and
/// learner participation: saving material never schedules it, while explicit enrollment owns
/// one durable relationship without taking over a Card's content or FSRS history.
final class LingroveNotebookReviewEnrollmentIntegrationTests: LocalDatabaseTestCase {
    func testSavingCollectedNotebookMaterialDoesNotEnrollUntilExplicitAtomicEnrollmentAndReopen() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let saved = try self.saveNotebook(Self.document(isCollected: true), in: database,
            workspaceId: workspaceId, operationId: "review-enrollment-save-source")
        let emptyReviewCounts = try database.loadReviewCounts(
            workspaceId: workspaceId, reviewQueryDefinition: .allCards, now: Self.referenceDate
        )

        XCTAssertTrue(try database.loadActiveCards(workspaceId: workspaceId).isEmpty)
        XCTAssertTrue(try database.loadLingroveNotebookReviewEnrollments(workspaceId: workspaceId).isEmpty)
        XCTAssertEqual(0, emptyReviewCounts.totalCount)
        XCTAssertEqual(0, try self.rowCount(database, "notebook_review_exercises"))
        XCTAssertEqual(0, try self.rowCount(database, "notebook_review_requests"))

        let draft = try self.draft(from: saved, intentId: Self.id(201))
        let createdEnrollments = try database.enrollLingroveNotebookSense(draft)
        let enrollment = try XCTUnwrap(createdEnrollments.first)
        let exercise = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(enrollment).first)
        let card = try database.loadActiveCard(workspaceId: workspaceId, cardId: exercise.cardId)
        let link = try XCTUnwrap(database.loadLingroveNotebookCardLinks(
            workspaceId: workspaceId, cardId: exercise.cardId
        ).first)

        XCTAssertEqual(1, createdEnrollments.count)
        XCTAssertEqual(draft.source.senseId, enrollment.senseId)
        XCTAssertEqual(exercise.linkId, link.id)
        XCTAssertEqual(1, try self.rowCount(database, "notebook_review_enrollments"))
        XCTAssertEqual(1, try self.rowCount(database, "notebook_review_exercises"))
        XCTAssertEqual(1, try self.rowCount(database, "notebook_review_requests"))
        XCTAssertGreaterThan(try self.rowCount(database, "notebook_review_operations"), 0)
        XCTAssertEqual(1, try self.rowCount(database, "notebook_card_sync_holds"))
        XCTAssertEqual(1, try database.loadActiveCards(workspaceId: workspaceId).count)

        // Closing the connection proves the facade committed enrollment, the Card, provenance,
        // and participation journals as one persistent SQLite result rather than shared memory.
        let databaseURL = try XCTUnwrap(self.databaseURL)
        try database.close()
        self.database = nil
        let reopened = try LocalDatabase(databaseURL: databaseURL)
        self.database = reopened

        XCTAssertEqual(createdEnrollments, try reopened.loadLingroveNotebookReviewEnrollments(workspaceId: workspaceId))
        XCTAssertEqual(card, try reopened.loadActiveCard(workspaceId: workspaceId, cardId: card.cardId))
        XCTAssertEqual([exercise], try reopened.lingroveNotebookReviewStore.exercises(enrollment))
        XCTAssertEqual([link], try reopened.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: card.cardId))
        XCTAssertEqual([card.cardId], try reopened.loadReviewHead(
            workspaceId: workspaceId, resolvedReviewFilter: .allCards,
            reviewQueryDefinition: .allCards, now: Self.referenceDate, limit: 10
        ).seedReviewQueue.map(\.cardId))
    }

    func testAdmissionRejectsFingerprintStaleScopeAndForgedProjectionWithoutWrites() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let saved = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "review-enrollment-admission-source")
        let staleDraft = try self.draft(from: saved, intentId: Self.id(202))
        let before = try self.persistenceCounts(database: database, workspaceId: workspaceId)

        let wrongWorkspace = Self.copy(staleDraft, source: .init(
            workspaceId: "another-workspace", notebookId: staleDraft.source.notebookId,
            entryId: staleDraft.source.entryId, senseId: staleDraft.source.senseId,
            exampleId: staleDraft.source.exampleId
        ))
        let wrongNotebook = Self.copy(staleDraft, source: .init(
            workspaceId: workspaceId, notebookId: Self.id(9_202), entryId: staleDraft.source.entryId,
            senseId: staleDraft.source.senseId, exampleId: staleDraft.source.exampleId
        ))
        let forgedProjection = Self.copy(staleDraft, generatedContent: .init(
            frontText: "forged prompt", backText: staleDraft.generatedContent.backText,
            tags: staleDraft.generatedContent.tags
        ))
        XCTAssertThrowsError(try database.enrollLingroveNotebookSense(wrongWorkspace))
        XCTAssertThrowsError(try database.enrollLingroveNotebookSense(wrongNotebook))
        XCTAssertThrowsError(try database.enrollLingroveNotebookSense(forgedProjection))

        let changedDocument = Self.document(expression: "a newer saved phrase")
        let current = try database.saveLingroveNotebook(
            changedDocument, basedOn: saved, operationId: "review-enrollment-admission-advance"
        )
        XCTAssertThrowsError(try database.enrollLingroveNotebookSense(staleDraft))
        XCTAssertEqual(before, try self.persistenceCounts(database: database, workspaceId: workspaceId))

        let validDraft = try self.draft(from: current, intentId: Self.id(203))
        let enrolled = try database.enrollLingroveNotebookSense(validDraft)
        let afterCreate = try self.persistenceCounts(database: database, workspaceId: workspaceId)
        let changedFingerprint = Self.copy(validDraft, generatedContent: .init(
            frontText: "same request ID, changed prompt", backText: validDraft.generatedContent.backText,
            tags: validDraft.generatedContent.tags
        ))

        XCTAssertThrowsError(try database.enrollLingroveNotebookSense(changedFingerprint))
        XCTAssertEqual(afterCreate, try self.persistenceCounts(database: database, workspaceId: workspaceId))
        XCTAssertEqual(1, enrolled.count)
        XCTAssertEqual(1, afterCreate.enrollments)
        XCTAssertEqual(1, afterCreate.cards)
    }

    func testRequestJournalFailureRollsBackEnrollmentCardLinkHoldAndExerciseTogether() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let saved = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "review-enrollment-rollback-source")
        let draft = try self.draft(from: saved, intentId: Self.id(204))
        let before = try self.persistenceCounts(database: database, workspaceId: workspaceId)

        // This trigger fails at the last enrollment write, after earlier inserts and the nested
        // Card/link/hold work have succeeded. The outer facade transaction must undo all of them.
        try database.core.executeScript(sql: """
            CREATE TRIGGER reject_notebook_review_request BEFORE INSERT ON notebook_review_requests
            BEGIN SELECT RAISE(ABORT, 'forced enrollment request failure'); END;
            """, errorContext: "Install notebook-review request failure trigger")
        XCTAssertThrowsError(try database.enrollLingroveNotebookSense(draft))

        XCTAssertEqual(before, try self.persistenceCounts(database: database, workspaceId: workspaceId))
        XCTAssertTrue(try database.loadActiveCards(workspaceId: workspaceId).isEmpty)
        XCTAssertTrue(try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, includingDeleted: true).isEmpty)
        XCTAssertTrue(try database.loadLingroveNotebookReviewEnrollments(workspaceId: workspaceId).isEmpty)
        try database.core.executeScript(sql: "DROP TRIGGER reject_notebook_review_request;",
            errorContext: "Remove notebook-review request failure trigger")
    }

    func testPauseWithdrawReplayAndFreshExampleEnrollmentPreserveCardsAndReviewEligibility() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let saved = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "review-enrollment-participation-source")
        let originalDraft = try self.draft(from: saved, intentId: Self.id(205))
        let originalGroup = try database.enrollLingroveNotebookSense(originalDraft)
        let originalEnrollment = try XCTUnwrap(originalGroup.first)
        let originalExercise = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(originalEnrollment).first)
        let originalCard = try database.loadActiveCard(workspaceId: workspaceId, cardId: originalExercise.cardId)

        // A legacy Card can have source provenance without being owned by enrollment. Its lack of
        // a notebook_review_exercises row keeps it in the normal review queue through a pause.
        let ordinaryCard = try database.saveCard(
            workspaceId: workspaceId,
            input: .init(frontText: "ordinary linked question", backText: "ordinary answer", tags: []),
            cardId: nil, mediaAssetIdsReadyForUpload: []
        )
        let ordinaryLinkDraft = try self.draft(from: saved, intentId: Self.id(206))
        let ordinaryLink = try database.linkLingroveNotebookCard(ordinaryLinkDraft, cardId: ordinaryCard.cardId)
        XCTAssertNil(ordinaryLink.generatedContent)
        XCTAssertTrue(try database.lingroveNotebookReviewStore.exercises(originalEnrollment).map(\.cardId)
            .allSatisfy { $0 != ordinaryCard.cardId })

        let reviewedCard = try database.submitReview(workspaceId: workspaceId, reviewSubmission: .init(
            cardId: originalCard.cardId, rating: .good,
            reviewedAtClient: "2026-08-08T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))
        let reviewCountAfterLearning = try self.rowCount(database, "review_events")
        XCTAssertEqual(1, reviewCountAfterLearning)
        let activeSurfaces = try self.reviewSurfaces(database: database, workspaceId: workspaceId)
        XCTAssertEqual(Set([originalCard.cardId, ordinaryCard.cardId]), activeSurfaces.headCardIds)
        XCTAssertEqual(activeSurfaces.headCardIds, activeSurfaces.timelineCardIds)
        XCTAssertEqual(2, activeSurfaces.totalCount)
        XCTAssertEqual(2, activeSurfaces.scheduleTotalCards)
        XCTAssertEqual(activeSurfaces.scheduleTotalCards, activeSurfaces.scheduleBucketTotal)

        let pauseRequestId = Self.id(207)
        let paused = try database.setLingroveNotebookReviewStatus(.paused,
            enrollments: originalGroup, requestId: pauseRequestId)
        XCTAssertEqual(.paused, try XCTUnwrap(paused.first).status)
        let pausedSurfaces = try self.reviewSurfaces(database: database, workspaceId: workspaceId)
        XCTAssertEqual(Set([ordinaryCard.cardId]), pausedSurfaces.headCardIds)
        XCTAssertEqual(pausedSurfaces.headCardIds, pausedSurfaces.timelineCardIds)
        XCTAssertEqual(1, pausedSurfaces.totalCount)
        XCTAssertEqual(1, pausedSurfaces.dueCount)
        XCTAssertEqual(1, pausedSurfaces.scheduleTotalCards)
        XCTAssertEqual(pausedSurfaces.scheduleTotalCards, pausedSurfaces.scheduleBucketTotal)
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: originalCard.cardId))
        XCTAssertThrowsError(try database.submitReview(workspaceId: workspaceId, reviewSubmission: .init(
            cardId: originalCard.cardId, rating: .again,
            reviewedAtClient: "2026-08-08T12:05:00.000Z", reviewedTimeZone: "UTC"
        )))
        XCTAssertEqual(reviewCountAfterLearning, try self.rowCount(database, "review_events"),
            "A blocked rating must not append an event")
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: originalCard.cardId))

        // The same CardStore review contract still admits the generic linked Card.
        let reviewedOrdinaryCard = try database.submitReview(workspaceId: workspaceId, reviewSubmission: .init(
            cardId: ordinaryCard.cardId, rating: .good,
            reviewedAtClient: "2026-08-08T12:10:00.000Z", reviewedTimeZone: "UTC"
        ))
        XCTAssertEqual(2, try self.rowCount(database, "review_events"))
        XCTAssertEqual(reviewedOrdinaryCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: ordinaryCard.cardId))

        let withdrawn = try database.setLingroveNotebookReviewStatus(.withdrawn,
            enrollments: paused, requestId: Self.id(208))
        XCTAssertEqual(.withdrawn, try XCTUnwrap(withdrawn.first).status)
        let withdrawnSurfaces = try self.reviewSurfaces(database: database, workspaceId: workspaceId)
        XCTAssertEqual(Set([ordinaryCard.cardId]), withdrawnSurfaces.headCardIds)
        XCTAssertEqual(withdrawnSurfaces.headCardIds, withdrawnSurfaces.timelineCardIds)
        XCTAssertEqual(1, withdrawnSurfaces.totalCount)
        XCTAssertEqual(1, withdrawnSurfaces.scheduleTotalCards)
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: originalCard.cardId))

        // An uncertain replay of the earlier pause returns current state; it does not reapply
        // the stale pause intent or undo the later withdrawal.
        let replayedPause = try database.setLingroveNotebookReviewStatus(.paused,
            enrollments: originalGroup, requestId: pauseRequestId)
        XCTAssertEqual(withdrawn, replayedPause)
        XCTAssertEqual(.withdrawn, try XCTUnwrap(replayedPause.first).status)

        let nextExampleDraft = try self.draft(from: saved, exampleId: Self.id(3), intentId: Self.id(209))
        let resumed = try database.enrollLingroveNotebookSense(nextExampleDraft)
        XCTAssertEqual([originalEnrollment.id], resumed.map(\.id))
        XCTAssertEqual(.active, try XCTUnwrap(resumed.first).status)
        XCTAssertEqual([originalExercise], try database.lingroveNotebookReviewStore.exercises(try XCTUnwrap(resumed.first)))
        XCTAssertEqual(2, try database.loadActiveCards(workspaceId: workspaceId).count)
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: originalCard.cardId))
        XCTAssertEqual(reviewedOrdinaryCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: ordinaryCard.cardId))
        XCTAssertEqual(2, try self.rowCount(database, "review_events"))

        let resumedSurfaces = try self.reviewSurfaces(database: database, workspaceId: workspaceId)
        XCTAssertEqual(Set([originalCard.cardId, ordinaryCard.cardId]), resumedSurfaces.headCardIds)
        XCTAssertEqual(resumedSurfaces.headCardIds, resumedSurfaces.timelineCardIds)
        XCTAssertEqual(2, resumedSurfaces.totalCount)
        XCTAssertEqual(2, resumedSurfaces.scheduleTotalCards)
    }

    func testMergedSensesRetainEnrollmentIdsAndRequireTheWholeGroupForStatusChanges() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let original = try self.saveNotebook(Self.document(withTwoSenses: true, includesExample: false),
            in: database, workspaceId: workspaceId, operationId: "review-enrollment-merge-source")
        let entry = try XCTUnwrap(original.document.entries.first)
        let removedSense = try XCTUnwrap(entry.senses.first)
        let survivingSense = try XCTUnwrap(entry.senses.last)
        let removedGroup = try database.enrollLingroveNotebookSense(try self.draft(from: original,
            selection: .init(entryID: entry.id, senseID: removedSense.id), intentId: Self.id(210)))
        let survivingGroup = try database.enrollLingroveNotebookSense(try self.draft(from: original,
            selection: .init(entryID: entry.id, senseID: survivingSense.id), intentId: Self.id(211)))
        let removedEnrollment = try XCTUnwrap(removedGroup.first)
        let survivingEnrollment = try XCTUnwrap(survivingGroup.first)
        let removedCardId = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(removedEnrollment).first).cardId
        let survivingCardId = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(survivingEnrollment).first).cardId
        let removedReviewedCard = try database.submitReview(workspaceId: workspaceId, reviewSubmission: .init(
            cardId: removedCardId, rating: .good,
            reviewedAtClient: "2026-08-09T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))
        let survivingReviewedCard = try database.submitReview(workspaceId: workspaceId, reviewSubmission: .init(
            cardId: survivingCardId, rating: .hard,
            reviewedAtClient: "2026-08-09T12:10:00.000Z", reviewedTimeZone: "UTC"
        ))

        var mergedDocument = original.document
        var mergedEntry = entry
        var mergedSense = survivingSense
        mergedSense.meaning = "combined meaning"
        mergedSense.mergedFrom = [removedSense.id]
        mergedEntry.senses = [mergedSense]
        mergedDocument.entries = [mergedEntry]
        let merged = try database.saveLingroveNotebook(
            mergedDocument, basedOn: original, restoringBackup: true, operationId: "review-enrollment-merge-commit"
        )
        let resolvedGroup = try database.enrollLingroveNotebookSense(try self.draft(from: merged,
            selection: .init(entryID: entry.id, senseID: survivingSense.id), intentId: Self.id(212)))

        XCTAssertEqual(Set([removedEnrollment.id, survivingEnrollment.id]), Set(resolvedGroup.map(\.id)))
        XCTAssertEqual(Set([removedSense.id, survivingSense.id]), Set(try [removedCardId, survivingCardId].map { cardId in
            try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: cardId).first).source.senseId
        }))
        XCTAssertThrowsError(try database.setLingroveNotebookReviewStatus(.paused,
            enrollments: [try XCTUnwrap(resolvedGroup.first)], requestId: Self.id(213)))

        // Merge follows generated materials but must retain each exercise's independent schedule.
        XCTAssertEqual("combined meaning", try database.loadActiveCard(workspaceId: workspaceId, cardId: removedCardId).backText)
        XCTAssertEqual("combined meaning", try database.loadActiveCard(workspaceId: workspaceId, cardId: survivingCardId).backText)
        let paused = try database.setLingroveNotebookReviewStatus(.paused,
            enrollments: resolvedGroup, requestId: Self.id(214))
        XCTAssertEqual(Set(resolvedGroup.map(\.id)), Set(paused.map(\.id)))
        XCTAssertTrue(paused.allSatisfy { $0.status == .paused })
        XCTAssertEqual(try notebookReviewProgressEvidence(removedReviewedCard), try notebookReviewProgressEvidence(database.loadActiveCard(workspaceId: workspaceId, cardId: removedCardId)))
        XCTAssertEqual(try notebookReviewProgressEvidence(survivingReviewedCard), try notebookReviewProgressEvidence(database.loadActiveCard(workspaceId: workspaceId, cardId: survivingCardId)))
        XCTAssertEqual(2, try self.rowCount(database, "review_events"))
        XCTAssertEqual([], try database.loadReviewHead(workspaceId: workspaceId,
            resolvedReviewFilter: .allCards, reviewQueryDefinition: .allCards,
            now: Self.referenceDate, limit: 10).seedReviewQueue)

        let resumed = try database.setLingroveNotebookReviewStatus(.active,
            enrollments: paused, requestId: Self.id(215))
        XCTAssertEqual(Set([removedEnrollment.id, survivingEnrollment.id]), Set(resumed.map(\.id)))
        XCTAssertTrue(resumed.allSatisfy { $0.status == .active })
        XCTAssertEqual(try notebookReviewProgressEvidence(removedReviewedCard), try notebookReviewProgressEvidence(database.loadActiveCard(workspaceId: workspaceId, cardId: removedCardId)))
        XCTAssertEqual(try notebookReviewProgressEvidence(survivingReviewedCard), try notebookReviewProgressEvidence(database.loadActiveCard(workspaceId: workspaceId, cardId: survivingCardId)))
        XCTAssertEqual(2, try self.rowCount(database, "review_events"))
    }

    func testMovingExampleWithoutSenseMergeDoesNotMoveEnrollmentCardOrReviewHistory() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let original = try self.saveNotebook(Self.document(withTwoSenses: true), in: database,
            workspaceId: workspaceId, operationId: "review-enrollment-example-source")
        let entry = try XCTUnwrap(original.document.entries.first)
        let originalSense = try XCTUnwrap(entry.senses.first)
        let destinationSense = try XCTUnwrap(entry.senses.last)
        let example = try XCTUnwrap(originalSense.examples.first)
        let originalEnrollment = try XCTUnwrap(try database.enrollLingroveNotebookSense(try self.draft(from: original,
            selection: .init(entryID: entry.id, senseID: originalSense.id), exampleId: example.id,
            intentId: Self.id(216))).first)
        let originalExercise = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(originalEnrollment).first)
        let originalCard = try database.loadActiveCard(workspaceId: workspaceId, cardId: originalExercise.cardId)
        let reviewedCard = try database.submitReview(workspaceId: workspaceId, reviewSubmission: .init(
            cardId: originalCard.cardId, rating: .good,
            reviewedAtClient: "2026-08-10T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))
        let originalLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(
            workspaceId: workspaceId, cardId: originalCard.cardId
        ).first)

        var movedDocument = original.document
        var movedEntry = entry
        var movedOriginalSense = originalSense
        var movedDestinationSense = destinationSense
        movedOriginalSense.examples = []
        movedDestinationSense.examples.append(example)
        movedEntry.senses = [movedOriginalSense, movedDestinationSense]
        movedDocument.entries = [movedEntry]
        let moved = try database.saveLingroveNotebook(
            movedDocument, basedOn: original, restoringBackup: true, operationId: "review-enrollment-example-move"
        )

        XCTAssertNil(LingroveNotebookCardMaterial.resolve(source: originalLink.source, snapshot: moved))
        let storedOriginalEnrollment = try XCTUnwrap(database.loadLingroveNotebookReviewEnrollments(
            workspaceId: workspaceId).first)
        XCTAssertEqual(originalEnrollment.id, storedOriginalEnrollment.id)
        XCTAssertEqual(originalSense.id, storedOriginalEnrollment.senseId)
        XCTAssertEqual(originalSense.id, originalLink.source.senseId)

        let destinationEnrollment = try XCTUnwrap(try database.enrollLingroveNotebookSense(try self.draft(from: moved,
            selection: .init(entryID: entry.id, senseID: destinationSense.id), exampleId: example.id,
            intentId: Self.id(217))).first)
        let destinationExercise = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(destinationEnrollment).first)
        let destinationCard = try database.loadActiveCard(workspaceId: workspaceId, cardId: destinationExercise.cardId)
        let destinationLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(
            workspaceId: workspaceId, cardId: destinationCard.cardId
        ).first)

        XCTAssertNotEqual(originalEnrollment.id, destinationEnrollment.id)
        XCTAssertNotEqual(originalCard.cardId, destinationCard.cardId)
        XCTAssertEqual(destinationSense.id, destinationLink.source.senseId)
        XCTAssertEqual(example.id, destinationLink.source.exampleId)
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: originalCard.cardId))
        XCTAssertEqual(1, try self.rowCount(database, "review_events"), "Review history stays on the original Card")
        XCTAssertEqual(0, destinationCard.reps)
        XCTAssertEqual(2, try database.loadActiveCards(workspaceId: workspaceId).count)
    }

    func testRemovedSourceCanBePausedOrWithdrawnButCannotBeReactivated() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let saved = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "review-enrollment-retire-source")
        let enrollment = try XCTUnwrap(try database.enrollLingroveNotebookSense(
            self.draft(from: saved, intentId: Self.id(218))).first)
        let exercise = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(enrollment).first)
        let card = try database.loadActiveCard(workspaceId: workspaceId, cardId: exercise.cardId)

        _ = try database.saveLingroveNotebook(VocabularyDocument(), basedOn: saved,
            restoringBackup: true, operationId: "review-enrollment-remove-source")
        let paused = try database.setLingroveNotebookReviewStatus(.paused,
            enrollments: [enrollment], requestId: Self.id(219))
        XCTAssertEqual(.paused, try XCTUnwrap(paused.first).status)
        XCTAssertThrowsError(try database.setLingroveNotebookReviewStatus(.active,
            enrollments: paused, requestId: Self.id(220)))

        let withdrawn = try database.setLingroveNotebookReviewStatus(.withdrawn,
            enrollments: paused, requestId: Self.id(221))
        XCTAssertEqual(.withdrawn, try XCTUnwrap(withdrawn.first).status)
        XCTAssertEqual(card, try database.loadActiveCard(workspaceId: workspaceId, cardId: card.cardId))
        XCTAssertEqual([enrollment.id], try database.loadLingroveNotebookReviewEnrollments(workspaceId: workspaceId).map(\.id))
        XCTAssertEqual([exercise], try database.lingroveNotebookReviewStore.exercises(try XCTUnwrap(withdrawn.first)))
    }

    func testFreshEnrollmentReplacesDeletedExerciseWithoutErasingItsTombstoneOrHistory() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let saved = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "review-enrollment-replacement-source")
        let firstDraft = try self.draft(from: saved, intentId: Self.id(222))
        let enrollment = try XCTUnwrap(try database.enrollLingroveNotebookSense(firstDraft).first)
        let oldExercise = try XCTUnwrap(database.lingroveNotebookReviewStore.exercises(enrollment).first)
        let oldCard = try database.loadActiveCard(workspaceId: workspaceId, cardId: oldExercise.cardId)
        _ = try database.submitReview(workspaceId: workspaceId, reviewSubmission: .init(
            cardId: oldCard.cardId, rating: .good,
            reviewedAtClient: "2026-08-11T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))
        let oldCardBeforeDelete = try database.loadActiveCard(workspaceId: workspaceId, cardId: oldCard.cardId)
        _ = try database.deleteCard(workspaceId: workspaceId, cardId: oldCard.cardId)

        let replacementGroup = try database.enrollLingroveNotebookSense(try self.draft(from: saved,
            intentId: Self.id(223)))
        let replacementEnrollment = try XCTUnwrap(replacementGroup.first)
        let exercises = try database.lingroveNotebookReviewStore.exercises(replacementEnrollment)
        let replacement = try XCTUnwrap(exercises.first(where: { $0.cardId != oldCard.cardId }))
        let replacementCard = try database.loadActiveCard(workspaceId: workspaceId, cardId: replacement.cardId)
        let oldCardRow = try XCTUnwrap(database.core.query(sql: """
            SELECT deleted_at,reps,fsrs_last_reviewed_at FROM cards WHERE workspace_id=? AND card_id=?
            """, values: [.text(workspaceId), .text(oldCard.cardId)]) { statement in
                (DatabaseCore.columnOptionalText(statement: statement, index: 0),
                 Int(DatabaseCore.columnInt64(statement: statement, index: 1)),
                 DatabaseCore.columnOptionalText(statement: statement, index: 2))
            }.first)

        XCTAssertEqual(enrollment.id, replacementEnrollment.id)
        XCTAssertEqual(.active, replacementEnrollment.status)
        XCTAssertEqual(2, exercises.count)
        XCTAssertNotNil(oldCardRow.0)
        XCTAssertEqual(oldCardBeforeDelete.reps, oldCardRow.1)
        XCTAssertEqual(oldCardBeforeDelete.fsrsLastReviewedAt, oldCardRow.2)
        XCTAssertEqual(0, replacementCard.reps, "A replacement starts new; the deleted exercise keeps its own history")
        XCTAssertEqual(1, try self.rowCount(database, "review_events"))
        XCTAssertEqual(1, try database.loadActiveCards(workspaceId: workspaceId).count)
        XCTAssertEqual(1, try database.loadLingroveNotebookCardLinks(
            workspaceId: workspaceId, cardId: oldCard.cardId, includingDeleted: true
        ).count)
    }

    private func saveNotebook(
        _ document: VocabularyDocument, in database: LocalDatabase, workspaceId: String, operationId: String
    ) throws -> LingroveNotebookSnapshot {
        let baseline = try database.loadLingroveNotebook(workspaceId: workspaceId)
        return try database.saveLingroveNotebook(document, basedOn: baseline, restoringBackup: true,
            operationId: operationId)
    }

    private func draft(
        from snapshot: LingroveNotebookSnapshot, selection: VocabularySelection? = nil,
        exampleId: UUID? = nil, intentId: UUID
    ) throws -> LingroveNotebookCardDraft {
        let entry = try XCTUnwrap(snapshot.document.entries.first)
        let sense = try XCTUnwrap(entry.senses.first)
        return try LingroveNotebookCardMaterial.draft(snapshot: snapshot,
            selection: selection ?? .init(entryID: entry.id, senseID: sense.id),
            exampleId: exampleId, intentId: intentId)
    }

    private func persistenceCounts(database: LocalDatabase, workspaceId: String) throws -> NotebookReviewPersistenceCounts {
        NotebookReviewPersistenceCounts(
            cards: try database.core.scalarInt(sql: "SELECT COUNT(*) FROM cards WHERE workspace_id=? AND deleted_at IS NULL",
                values: [.text(workspaceId)]),
            links: try self.rowCount(database, "notebook_card_links"),
            linkOperations: try self.rowCount(database, "notebook_card_link_operations"),
            holds: try self.rowCount(database, "notebook_card_sync_holds"),
            heldOperations: try self.rowCount(database, "notebook_held_card_operations"),
            enrollments: try self.rowCount(database, "notebook_review_enrollments"),
            exercises: try self.rowCount(database, "notebook_review_exercises"),
            reviewOperations: try self.rowCount(database, "notebook_review_operations"),
            requests: try self.rowCount(database, "notebook_review_requests"),
            cardOutbox: try database.core.scalarInt(sql: "SELECT COUNT(*) FROM outbox WHERE workspace_id=? AND entity_type='card'",
                values: [.text(workspaceId)])
        )
    }

    private func reviewSurfaces(database: LocalDatabase, workspaceId: String) throws -> NotebookReviewSurfaces {
        let head = try database.loadReviewHead(workspaceId: workspaceId,
            resolvedReviewFilter: .allCards, reviewQueryDefinition: .allCards,
            now: Self.referenceDate, limit: 20)
        let timeline = try database.loadReviewTimelinePage(workspaceId: workspaceId,
            reviewQueryDefinition: .allCards, now: Self.referenceDate, limit: 20, offset: 0)
        let counts = try database.loadReviewCounts(workspaceId: workspaceId,
            reviewQueryDefinition: .allCards, now: Self.referenceDate)
        let schedule = try database.cardStore.loadReviewSchedule(workspaceIds: [workspaceId],
            timeZone: "UTC", referenceLocalDate: "2026-10-31")
        return NotebookReviewSurfaces(
            headCardIds: Set(head.seedReviewQueue.map(\.cardId)),
            timelineCardIds: Set(timeline.cards.map(\.cardId)),
            totalCount: counts.totalCount,
            dueCount: counts.dueCount,
            scheduleTotalCards: schedule.totalCards,
            scheduleBucketTotal: schedule.buckets.reduce(0) { $0 + $1.count }
        )
    }

    private func rowCount(_ database: LocalDatabase, _ tableName: String) throws -> Int {
        try database.core.scalarInt(sql: "SELECT COUNT(*) FROM \(tableName)", values: [])
    }

    private static let referenceDate = parseIsoTimestamp(value: "2026-10-31T12:00:00.000Z")!

    private static func copy(
        _ draft: LingroveNotebookCardDraft,
        source: LingroveNotebookCardSource? = nil,
        generatedContent: CardEditorInput? = nil
    ) -> LingroveNotebookCardDraft {
        .init(id: draft.id, source: source ?? draft.source, sourceRevision: draft.sourceRevision,
            generatedContent: generatedContent ?? draft.generatedContent)
    }

    private static func document(
        expression: String = "break down", meaning: String = "to separate into parts",
        isCollected: Bool = false, withTwoSenses: Bool = false, includesExample: Bool = true
    ) -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let examples = includesExample ? [VocabularyExample(
            id: Self.id(3), sourceID: Self.id(4), occurrenceID: Self.id(5), sourceKind: .captured,
            text: "The old system broke down.", translation: "旧系统出故障了。", translationLanguage: .chinese,
            ranges: [], completeness: .sentence, meaning: "stop working", meaningLanguage: .english,
            meaningOrigin: .user, createdAt: now
        )] : []
        let firstSense = VocabularySense(
            id: Self.id(2), meaning: meaning, meaningLanguage: .english, meaningOrigin: .user,
            tags: ["phrasal-verb"], examples: examples, isSavedWithoutContext: isCollected,
            createdAt: now, updatedAt: now
        )
        var senses = [firstSense]
        if withTwoSenses {
            senses.append(VocabularySense(
                id: Self.id(7), meaning: "to lose control", meaningLanguage: .english, meaningOrigin: .user,
                tags: ["idiom"], createdAt: now, updatedAt: now
            ))
        }
        let entry = VocabularyEntry(
            id: Self.id(1), expression: expression, dictionaryForm: expression, language: .english,
            kind: .expression, senses: senses, createdAt: now, updatedAt: now
        )
        return VocabularyDocument(entries: [entry])
    }

    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", value))")!
    }
}

private struct NotebookReviewPersistenceCounts: Equatable {
    let cards: Int
    let links: Int
    let linkOperations: Int
    let holds: Int
    let heldOperations: Int
    let enrollments: Int
    let exercises: Int
    let reviewOperations: Int
    let requests: Int
    let cardOutbox: Int
}

private struct NotebookReviewSurfaces {
    let headCardIds: Set<String>
    let timelineCardIds: Set<String>
    let totalCount: Int
    let dueCount: Int
    let scheduleTotalCards: Int
    let scheduleBucketTotal: Int
}
