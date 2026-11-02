import Foundation
import LingroveNotebook
import XCTest
@testable import LingroveNotebookEngine

/// These cases cross the portable notebook values, the existing CardStore and a real SQLite
/// connection. They protect the ownership boundary: a notebook link records where an exercise
/// came from, while Card and FSRS remain the durable owners of review content and history.
final class LingroveNotebookCardLinkIntegrationTests: LocalDatabaseTestCase {
    func testMakingAndDiscardingADraftDoesNotPersistACardOrLink() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let emptyBook = try database.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(VocabularyDocument(), emptyBook.document)

        let savedBook = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "card-link-draft-source")
        let before = try self.persistenceCounts(database: database, workspaceId: workspaceId)
        let draft = try self.draft(from: savedBook, intentId: Self.id(100))

        XCTAssertEqual(savedBook.revision, draft.sourceRevision)
        XCTAssertEqual(0, before.cards)
        XCTAssertEqual(0, before.links)
        XCTAssertEqual(0, before.linkOperations)
        XCTAssertEqual(0, before.holds)
        XCTAssertEqual(0, before.heldOperations)
        XCTAssertEqual(before, try self.persistenceCounts(database: database, workspaceId: workspaceId))
        XCTAssertEqual(savedBook, try database.loadLingroveNotebook(workspaceId: workspaceId))
        XCTAssertTrue(try database.loadActiveCards(workspaceId: workspaceId).isEmpty)
        XCTAssertTrue(try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId).isEmpty)
    }

    func testCreationIntentReplayIsIdempotentButANewIntentCreatesAnotherExercise() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let baseline = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId, operationId: "card-link-intent-source")
        let intentId = Self.id(101)
        let draft = try self.draft(from: baseline, intentId: intentId)

        let created = try self.createLinkedCard(draft, in: database)
        XCTAssertEqual(created, try self.createLinkedCard(draft, in: database))
        XCTAssertEqual(1, try database.loadActiveCards(workspaceId: workspaceId).count)
        XCTAssertEqual(1, try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId).count)

        // A retry after a later native edit returns the current Card instead of replaying the
        // frozen draft over work the learner has already done.
        let manual = CardEditorInput(frontText: "my edited front", backText: created.backText, tags: created.tags)
        let edited = try database.saveCard(
            workspaceId: workspaceId,
            input: manual,
            cardId: created.cardId,
            mediaAssetIdsReadyForUpload: []
        )
        XCTAssertEqual(edited, try self.createLinkedCard(draft, in: database))

        let secondDraft = try self.draft(from: baseline, intentId: Self.id(102))
        let secondCard = try self.createLinkedCard(secondDraft, in: database)
        XCTAssertNotEqual(created.cardId, secondCard.cardId)
        XCTAssertEqual(2, try database.loadActiveCards(workspaceId: workspaceId).count)
        XCTAssertEqual(2, try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId).count)
    }

    func testCreationIntentRejectsChangedIdentityAndReplaysDeletedCardAsTombstone() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let baseline = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "card-link-tombstone-source")
        let draft = try self.draft(from: baseline, intentId: Self.id(114))
        let card = try self.createLinkedCard(draft, in: database)
        let committed = try self.persistenceCounts(database: database, workspaceId: workspaceId)

        let changedInput = CardEditorInput(
            frontText: "changed immutable front", backText: draft.generatedContent.backText,
            tags: draft.generatedContent.tags
        )
        XCTAssertThrowsError(try database.saveCard(
            workspaceId: workspaceId, input: changedInput, cardId: nil,
            mediaAssetIdsReadyForUpload: [], notebookDraft: draft
        ))
        XCTAssertEqual(committed, try self.persistenceCounts(database: database, workspaceId: workspaceId))

        let changedSource = LingroveNotebookCardSource(
            workspaceId: draft.source.workspaceId, notebookId: draft.source.notebookId,
            entryId: Self.id(9_998), senseId: draft.source.senseId, exampleId: draft.source.exampleId
        )
        XCTAssertThrowsError(try self.createLinkedCard(Self.copy(draft, source: changedSource), in: database))
        XCTAssertEqual(committed, try self.persistenceCounts(database: database, workspaceId: workspaceId))

        let reviewed = try database.submitReview(workspaceId: workspaceId, reviewSubmission: ReviewSubmission(
            cardId: card.cardId, rating: .good, reviewedAtClient: "2026-08-08T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))
        let reviewHistoryCount = try self.rowCount(database, "review_events")
        XCTAssertEqual(1, reviewHistoryCount)

        let tombstone = try database.deleteCard(workspaceId: workspaceId, cardId: reviewed.cardId)
        XCTAssertNotNil(tombstone.deletedAt)
        let countsAfterDelete = try self.persistenceCounts(database: database, workspaceId: workspaceId)
        let replayed = try self.createLinkedCard(draft, in: database)

        XCTAssertEqual(tombstone, replayed)
        XCTAssertNotNil(replayed.deletedAt, "Replaying an intent must not revive its deleted Card")
        XCTAssertEqual(countsAfterDelete, try self.persistenceCounts(database: database, workspaceId: workspaceId))
        XCTAssertTrue(try database.loadActiveCards(workspaceId: workspaceId).isEmpty)
        XCTAssertEqual(1, try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: card.cardId).count)
        XCTAssertEqual(1, try self.rowCount(database, "notebook_card_sync_holds"))
        XCTAssertEqual(reviewHistoryCount, try self.rowCount(database, "review_events"))
    }

    func testStaleWrongWorkspaceWrongBookAndForgedProjectionAreRejectedWithoutWrites() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let baseline = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId, operationId: "card-link-admission-source")
        let validDraft = try self.draft(from: baseline, intentId: Self.id(103))
        let before = try self.persistenceCounts(database: database, workspaceId: workspaceId)

        let wrongWorkspaceSource = LingroveNotebookCardSource(
            workspaceId: "another-workspace", notebookId: validDraft.source.notebookId,
            entryId: validDraft.source.entryId, senseId: validDraft.source.senseId,
            exampleId: validDraft.source.exampleId
        )
        let wrongWorkspace = Self.copy(validDraft, source: wrongWorkspaceSource)
        XCTAssertThrowsError(try self.createLinkedCard(wrongWorkspace, in: database))

        let wrongBookSource = LingroveNotebookCardSource(workspaceId: workspaceId, notebookId: Self.id(9_999),
            entryId: validDraft.source.entryId, senseId: validDraft.source.senseId, exampleId: validDraft.source.exampleId)
        XCTAssertThrowsError(try self.createLinkedCard(Self.copy(validDraft, source: wrongBookSource), in: database))

        let forged = Self.copy(validDraft, generatedContent: CardEditorInput(
            frontText: "forged projection", backText: validDraft.generatedContent.backText, tags: validDraft.generatedContent.tags
        ))
        XCTAssertThrowsError(try self.createLinkedCard(forged, in: database))

        let changed = Self.document(expression: "new notebook revision")
        let current = try database.saveLingroveNotebook(changed, basedOn: baseline, operationId: "card-link-admission-advance")
        XCTAssertGreaterThan(current.revision, validDraft.sourceRevision)
        XCTAssertThrowsError(try self.createLinkedCard(validDraft, in: database))

        XCTAssertEqual(0, try database.loadActiveCards(workspaceId: workspaceId).count)
        XCTAssertTrue(try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId).isEmpty)
        XCTAssertEqual(before.outbox, try self.persistenceCounts(database: database, workspaceId: workspaceId).outbox)
        XCTAssertEqual(0, try self.rowCount(database, "notebook_card_link_operations"))
        XCTAssertEqual(0, try self.rowCount(database, "notebook_card_sync_holds"))
    }

    func testLinkAndHoldInsertFailuresRollBackTheEarlierCardAndOutboxWrites() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let baseline = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId, operationId: "card-link-rollback-source")
        let before = try self.persistenceCounts(database: database, workspaceId: workspaceId)

        try database.core.executeScript(sql: """
            CREATE TRIGGER reject_notebook_card_link BEFORE INSERT ON notebook_card_links
            BEGIN SELECT RAISE(ABORT, 'forced link insert failure'); END;
            """, errorContext: "Install notebook-card link failure trigger")
        XCTAssertThrowsError(try self.createLinkedCard(try self.draft(from: baseline, intentId: Self.id(104)), in: database))
        try self.assertCreationRollback(database: database, workspaceId: workspaceId, expected: before)
        try database.core.executeScript(sql: "DROP TRIGGER reject_notebook_card_link;", errorContext: "Remove link failure trigger")

        // This failure happens after Card, outbox, link, and link journal writes. The enclosing
        // transaction must roll all of them back together when the hold cannot be installed.
        try database.core.executeScript(sql: """
            CREATE TRIGGER reject_notebook_card_hold BEFORE INSERT ON notebook_card_sync_holds
            BEGIN SELECT RAISE(ABORT, 'forced hold insert failure'); END;
            """, errorContext: "Install notebook-card hold failure trigger")
        XCTAssertThrowsError(try self.createLinkedCard(try self.draft(from: baseline, intentId: Self.id(105)), in: database))
        try self.assertCreationRollback(database: database, workspaceId: workspaceId, expected: before)
    }

    func testManualEditsStayInCardsAndRefreshPreservesThenCanReplaceThemExplicitly() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let initial = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId, operationId: "card-link-refresh-source")
        let draft = try self.draft(from: initial, intentId: Self.id(106))
        let created = try self.createLinkedCard(draft, in: database)

        let reviewed = try database.submitReview(workspaceId: workspaceId, reviewSubmission: ReviewSubmission(
            cardId: created.cardId, rating: .good, reviewedAtClient: "2026-08-03T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))
        let historyCount = try self.rowCount(database, "review_events")
        let manualInput = CardEditorInput(frontText: "a learner-owned prompt", backText: reviewed.backText, tags: ["personal"])
        let manuallyEdited = try database.saveCard(
            workspaceId: workspaceId, input: manualInput, cardId: reviewed.cardId, mediaAssetIdsReadyForUpload: []
        )
        XCTAssertEqual(initial, try database.loadLingroveNotebook(workspaceId: workspaceId))
        XCTAssertEqual(Self.fsrsState(reviewed), Self.fsrsState(manuallyEdited))
        XCTAssertEqual(historyCount, try self.rowCount(database, "review_events"))

        var replacementDocument = initial.document
        var entry = try XCTUnwrap(replacementDocument.entries.first)
        entry.expression = "updated expression"
        entry.senses[0].meaning = "updated answer"
        entry.senses[0].tags = ["updated-source"]
        replacementDocument.entries = [entry]
        let latest = try database.saveLingroveNotebook(
            replacementDocument, basedOn: initial, operationId: "card-link-refresh-latest-source"
        )
        let currentLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: created.cardId).first)

        let refreshed = try database.refreshLingroveNotebookCard(currentLink, basedOn: latest)
        XCTAssertEqual("a learner-owned prompt", refreshed.frontText)
        XCTAssertEqual("updated answer", refreshed.backText)
        XCTAssertEqual(["personal"], refreshed.tags)
        XCTAssertEqual(Self.fsrsState(reviewed), Self.fsrsState(refreshed))
        XCTAssertEqual(historyCount, try self.rowCount(database, "review_events"))

        let refreshedLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: created.cardId).first)
        let forced = try database.refreshLingroveNotebookCard(refreshedLink, basedOn: latest, replacingManualContent: true)
        let latestGenerated = try XCTUnwrap(LingroveNotebookCardMaterial.resolve(source: refreshedLink.source, snapshot: latest)).content
        XCTAssertEqual(latestGenerated, CardEditorInput(frontText: forced.frontText, backText: forced.backText, tags: forced.tags))
        XCTAssertEqual(Self.fsrsState(reviewed), Self.fsrsState(forced))
        XCTAssertEqual(historyCount, try self.rowCount(database, "review_events"))
    }

    func testAssociatingAnExistingCardOnlyAddsOneUnheldLink() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let baseline = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId, operationId: "card-link-associate-source")
        let existingCard = try database.saveCard(
            workspaceId: workspaceId,
            input: CardEditorInput(frontText: "native question", backText: "native answer", tags: ["native"]),
            cardId: nil,
            mediaAssetIdsReadyForUpload: []
        )
        let beforeOutbox = Set(try database.loadOutboxEntries(workspaceId: workspaceId, limit: Int.max).map(\.operationId))
        let beforeHistory = try self.rowCount(database, "review_events")
        let draft = try self.draft(from: baseline, intentId: Self.id(107))

        let link = try database.linkLingroveNotebookCard(draft, cardId: existingCard.cardId)
        XCTAssertNil(link.generatedContent)
        XCTAssertEqual(link, try database.linkLingroveNotebookCard(draft, cardId: existingCard.cardId))
        let secondIntent = try self.draft(from: baseline, intentId: Self.id(108))
        XCTAssertEqual(link, try database.linkLingroveNotebookCard(secondIntent, cardId: existingCard.cardId))

        XCTAssertEqual(existingCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: existingCard.cardId))
        XCTAssertEqual(beforeHistory, try self.rowCount(database, "review_events"))
        XCTAssertEqual(beforeOutbox, Set(try database.loadOutboxEntries(workspaceId: workspaceId, limit: Int.max).map(\.operationId)))
        XCTAssertEqual(1, try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: existingCard.cardId).count)
        XCTAssertEqual(0, try self.rowCount(database, "notebook_card_sync_holds"))
        XCTAssertEqual(0, try self.rowCount(database, "notebook_held_card_operations"))
    }

    func testMergedSenseAndMovedExampleKeepTheirHistoricalCardSourcesResolvable() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let original = try self.saveNotebook(Self.document(withTwoSenses: true), in: database,
            workspaceId: workspaceId, operationId: "card-link-merge-source")
        let originalEntry = try XCTUnwrap(original.document.entries.first)
        let removedSense = try XCTUnwrap(originalEntry.senses.first)
        let destinationSense = try XCTUnwrap(originalEntry.senses.last)
        let ordinaryDraft = try self.draft(from: original, selection: VocabularySelection(entryID: originalEntry.id, senseID: removedSense.id),
            intentId: Self.id(109))
        let exampleDraft = try self.draft(from: original, selection: VocabularySelection(entryID: originalEntry.id, senseID: removedSense.id),
            exampleId: Self.id(3), intentId: Self.id(110))
        let ordinaryCard = try self.createLinkedCard(ordinaryDraft, in: database)
        let exampleCard = try self.createLinkedCard(exampleDraft, in: database)
        var ordinaryLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: ordinaryCard.cardId).first)
        var exampleLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: exampleCard.cardId).first)

        var mergedDocument = original.document
        var mergedEntry = originalEntry
        var mergedSense = destinationSense
        mergedSense.meaning = "combined meaning"
        mergedSense.mergedFrom = [removedSense.id]
        let movedExample = try XCTUnwrap(removedSense.examples.first)
        mergedSense.examples.append(movedExample)
        mergedEntry.expression = "updated expression"
        mergedEntry.senses = [mergedSense]
        mergedDocument.entries = [mergedEntry]
        let merged = try database.saveLingroveNotebook(
            mergedDocument, basedOn: original, restoringBackup: true, operationId: "card-link-merge-replace"
        )

        let ordinaryMaterial = try XCTUnwrap(LingroveNotebookCardMaterial.resolve(source: ordinaryLink.source, snapshot: merged))
        let exampleMaterial = try XCTUnwrap(LingroveNotebookCardMaterial.resolve(source: exampleLink.source, snapshot: merged))
        XCTAssertEqual(destinationSense.id, ordinaryMaterial.selection.senseID)
        XCTAssertEqual(destinationSense.id, exampleMaterial.selection.senseID)
        XCTAssertEqual(movedExample.id, exampleMaterial.exampleId)

        // The source transaction has already advanced this material's CAS baseline.
        ordinaryLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: ordinaryCard.cardId).first)
        exampleLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: exampleCard.cardId).first)
        let refreshedOrdinary = try database.refreshLingroveNotebookCard(ordinaryLink, basedOn: merged)
        let refreshedExample = try database.refreshLingroveNotebookCard(exampleLink, basedOn: merged)
        XCTAssertEqual("updated expression", refreshedOrdinary.frontText)
        XCTAssertEqual(exampleMaterial.content.frontText, refreshedExample.frontText)
        // A merge changes where this historical source resolves, not the ID stored on the link.
        XCTAssertEqual(removedSense.id, try XCTUnwrap(database.loadLingroveNotebookCardLinks(
            workspaceId: workspaceId, cardId: ordinaryCard.cardId
        ).first).source.senseId)
    }

    func testUncollectingReplacingTheSourceAndUnlinkingPreserveCardAndReviewHistory() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let originalDocument = Self.document(isCollected: true)
        let original = try self.saveNotebook(originalDocument, in: database, workspaceId: workspaceId,
            operationId: "card-link-retirement-source")
        let draft = try self.draft(from: original, intentId: Self.id(111))
        let card = try self.createLinkedCard(draft, in: database)
        let reviewedCard = try database.submitReview(workspaceId: workspaceId, reviewSubmission: ReviewSubmission(
            cardId: card.cardId, rating: .good, reviewedAtClient: "2026-08-04T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))
        let link = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: card.cardId).first)
        let historyCount = try self.rowCount(database, "review_events")

        var uncollectedDocument = original.document
        var entry = try XCTUnwrap(uncollectedDocument.entries.first)
        entry.senses[0].isSavedWithoutContext = false
        uncollectedDocument.entries = [entry]
        let uncollected = try database.saveLingroveNotebook(
            uncollectedDocument, basedOn: original, operationId: "card-link-uncollect"
        )
        XCTAssertFalse(try XCTUnwrap(uncollected.document.entries.first?.senses.first).isSavedWithoutContext)
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: card.cardId))
        XCTAssertEqual(historyCount, try self.rowCount(database, "review_events"))
        let followedLink = try XCTUnwrap(database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: card.cardId).first)
        XCTAssertEqual(link.source, followedLink.source)
        XCTAssertGreaterThan(followedLink.revision, link.revision)

        // A complete backup can remove the source object without cascading into CardStore. The
        // retained link stays a historical reference and resolves as unavailable until restored.
        let emptyBackup = VocabularyDocument()
        let replaced = try database.saveLingroveNotebook(
            emptyBackup, basedOn: uncollected, restoringBackup: true, operationId: "card-link-source-removed"
        )
        XCTAssertNil(LingroveNotebookCardMaterial.resolve(source: link.source, snapshot: replaced))
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: card.cardId))
        XCTAssertEqual(historyCount, try self.rowCount(database, "review_events"))

        let tombstone = try database.unlinkLingroveNotebookCard(followedLink)
        XCTAssertNotNil(tombstone.deletedAt)
        XCTAssertEqual(tombstone, try XCTUnwrap(database.loadLingroveNotebookCardLinks(
            workspaceId: workspaceId, cardId: card.cardId, includingDeleted: true
        ).first))
        XCTAssertTrue(try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, cardId: card.cardId).isEmpty)
        XCTAssertEqual(reviewedCard, try database.loadActiveCard(workspaceId: workspaceId, cardId: card.cardId))
        XCTAssertEqual(historyCount, try self.rowCount(database, "review_events"))
        XCTAssertEqual(1, try self.rowCount(database, "notebook_card_sync_holds"))
    }

    func testNotebookCardAndReviewOperationsStayHeldWhileOrdinaryCardsRemainInLegacyOutbox() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let baseline = try self.saveNotebook(Self.document(), in: database, workspaceId: workspaceId,
            operationId: "card-link-held-sync-source")
        let ordinaryCard = try database.saveCard(
            workspaceId: workspaceId, input: CardEditorInput(frontText: "ordinary card", backText: "answer", tags: []),
            cardId: nil, mediaAssetIdsReadyForUpload: []
        )
        let linkedCard = try self.createLinkedCard(try self.draft(from: baseline, intentId: Self.id(112)), in: database)
        _ = try database.submitReview(workspaceId: workspaceId, reviewSubmission: ReviewSubmission(
            cardId: linkedCard.cardId, rating: .good, reviewedAtClient: "2026-08-05T12:00:00.000Z", reviewedTimeZone: "UTC"
        ))

        let legacy = try database.loadOutboxEntries(workspaceId: workspaceId, limit: Int.max)
        XCTAssertTrue(legacy.contains { $0.operation.entityId == ordinaryCard.cardId && $0.operation.entityType == .card })
        XCTAssertFalse(legacy.contains { $0.operation.entityId == linkedCard.cardId })
        XCTAssertEqual(3, try database.core.scalarInt(
            sql: "SELECT COUNT(*) FROM notebook_held_card_operations WHERE workspace_id=? AND subject_card_id=?",
            values: [.text(workspaceId), .text(linkedCard.cardId)]
        ))
        XCTAssertEqual(Set(["card", "review_event"]), Set(try database.core.query(
            sql: "SELECT DISTINCT entity_type FROM notebook_held_card_operations WHERE workspace_id=? AND subject_card_id=?",
            values: [.text(workspaceId), .text(linkedCard.cardId)]
        ) { DatabaseCore.columnText(statement: $0, index: 0) }))
        XCTAssertEqual(3, try database.core.scalarInt(
            sql: """
                SELECT COUNT(*) FROM notebook_local_pending_operations
                WHERE operation_id IN (
                    SELECT operation_id FROM notebook_held_card_operations
                    WHERE workspace_id=? AND subject_card_id=?
                )
                """,
            values: [.text(workspaceId), .text(linkedCard.cardId)]
        ))

        // The legacy acknowledgement/cleanup boundary only sees the old outbox. Clearing it must
        // leave every held notebook operation visible to the local pending-progress overlay.
        try database.deleteAllOutboxEntries(workspaceId: workspaceId)
        XCTAssertEqual(3, try database.core.scalarInt(
            sql: "SELECT COUNT(*) FROM notebook_held_card_operations WHERE workspace_id=? AND subject_card_id=?",
            values: [.text(workspaceId), .text(linkedCard.cardId)]
        ))
        let installationId = try database.workspaceSettingsStore.loadCloudSettings().installationId
        XCTAssertTrue(try database.hasPendingReviewScheduleImpactingCardOperation(
            workspaceId: workspaceId, installationId: installationId
        ))
        XCTAssertEqual(1, try database.loadPendingReviewScheduleCardTotalDelta(
            workspaceIds: [workspaceId], installationId: installationId
        ))

        let anotherOrdinaryCard = try database.saveCard(
            workspaceId: workspaceId, input: CardEditorInput(frontText: "another ordinary card", backText: "answer", tags: []),
            cardId: nil, mediaAssetIdsReadyForUpload: []
        )
        XCTAssertTrue(try database.loadOutboxEntries(workspaceId: workspaceId, limit: Int.max).contains {
            $0.operation.entityId == anotherOrdinaryCard.cardId && $0.operation.entityType == .card
        })
    }



    private func saveNotebook(
        _ document: VocabularyDocument,
        in database: LocalDatabase,
        workspaceId: String,
        operationId: String
    ) throws -> LingroveNotebookSnapshot {
        let baseline = try database.loadLingroveNotebook(workspaceId: workspaceId)
        return try database.saveLingroveNotebook(document, basedOn: baseline, restoringBackup: true, operationId: operationId)
    }

    private func draft(
        from snapshot: LingroveNotebookSnapshot,
        selection: VocabularySelection? = nil,
        exampleId: UUID? = nil,
        intentId: UUID
    ) throws -> LingroveNotebookCardDraft {
        let entry = try XCTUnwrap(snapshot.document.entries.first)
        let sense = try XCTUnwrap(entry.senses.first)
        return try LingroveNotebookCardMaterial.draft(
            snapshot: snapshot,
            selection: selection ?? VocabularySelection(entryID: entry.id, senseID: sense.id),
            exampleId: exampleId,
            intentId: intentId
        )
    }

    private func createLinkedCard(_ draft: LingroveNotebookCardDraft, in database: LocalDatabase) throws -> Card {
        try database.saveCard(
            workspaceId: draft.source.workspaceId,
            input: draft.generatedContent,
            cardId: nil,
            mediaAssetIdsReadyForUpload: [],
            notebookDraft: draft
        )
    }

    private func assertCreationRollback(
        database: LocalDatabase,
        workspaceId: String,
        expected: NotebookCardPersistenceCounts
    ) throws {
        XCTAssertEqual(expected, try self.persistenceCounts(database: database, workspaceId: workspaceId))
        XCTAssertTrue(try database.loadActiveCards(workspaceId: workspaceId).isEmpty)
        XCTAssertTrue(try database.loadLingroveNotebookCardLinks(workspaceId: workspaceId, includingDeleted: true).isEmpty)
        for table in ["notebook_card_link_operations", "notebook_card_sync_holds", "notebook_held_card_operations"] {
            XCTAssertEqual(0, try self.rowCount(database, table), "Failed creation left rows in \(table)")
        }
    }

    private func persistenceCounts(database: LocalDatabase, workspaceId: String) throws -> NotebookCardPersistenceCounts {
        NotebookCardPersistenceCounts(
            cards: try database.core.scalarInt(sql: "SELECT COUNT(*) FROM cards WHERE workspace_id=?", values: [.text(workspaceId)]),
            links: try self.rowCount(database, "notebook_card_links"),
            linkOperations: try self.rowCount(database, "notebook_card_link_operations"),
            holds: try self.rowCount(database, "notebook_card_sync_holds"),
            heldOperations: try self.rowCount(database, "notebook_held_card_operations"),
            outbox: try database.core.scalarInt(sql: "SELECT COUNT(*) FROM outbox WHERE workspace_id=?", values: [.text(workspaceId)])
        )
    }

    private func rowCount(_ database: LocalDatabase, _ tableName: String) throws -> Int {
        try database.core.scalarInt(sql: "SELECT COUNT(*) FROM \(tableName)", values: [])
    }

    private static func copy(
        _ draft: LingroveNotebookCardDraft,
        source: LingroveNotebookCardSource? = nil,
        generatedContent: CardEditorInput? = nil
    ) -> LingroveNotebookCardDraft {
        LingroveNotebookCardDraft(
            id: draft.id,
            source: source ?? draft.source,
            sourceRevision: draft.sourceRevision,
            generatedContent: generatedContent ?? draft.generatedContent
        )
    }

    private static func fsrsState(_ card: Card) -> NotebookCardFSRSState {
        NotebookCardFSRSState(
            dueAt: card.dueAt,
            reps: card.reps,
            lapses: card.lapses,
            state: card.fsrsCardState,
            stepIndex: card.fsrsStepIndex,
            stability: card.fsrsStability,
            difficulty: card.fsrsDifficulty,
            lastReviewedAt: card.fsrsLastReviewedAt,
            scheduledDays: card.fsrsScheduledDays
        )
    }

    private static func document(
        expression: String = "break down",
        meaning: String = "to separate into parts",
        isCollected: Bool = false,
        withTwoSenses: Bool = false
    ) -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let example = VocabularyExample(
            id: Self.id(3), sourceID: Self.id(4), occurrenceID: Self.id(5), sourceKind: .captured,
            text: "The old system broke down.", translation: "旧系统出故障了。", translationLanguage: .chinese,
            ranges: [], completeness: .sentence, meaning: "stop working", meaningLanguage: .english,
            meaningOrigin: .user, createdAt: now
        )
        let firstSense = VocabularySense(
            id: Self.id(2), meaning: meaning, meaningLanguage: .english, meaningOrigin: .user,
            tags: ["phrasal-verb"], examples: [example], isSavedWithoutContext: isCollected,
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

private struct NotebookCardPersistenceCounts: Equatable {
    let cards: Int
    let links: Int
    let linkOperations: Int
    let holds: Int
    let heldOperations: Int
    let outbox: Int
}

/// The editable Card boundary owns its scheduler fields independently of source refresh.
private struct NotebookCardFSRSState: Equatable {
    let dueAt: String?
    let reps: Int
    let lapses: Int
    let state: FsrsCardState
    let stepIndex: Int?
    let stability: Double?
    let difficulty: Double?
    let lastReviewedAt: String?
    let scheduledDays: Int?
}
