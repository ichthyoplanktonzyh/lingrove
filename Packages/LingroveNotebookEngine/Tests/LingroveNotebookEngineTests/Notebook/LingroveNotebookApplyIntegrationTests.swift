import Foundation
import LingroveNotebook
import LingroveNotebookStorage
import LingroveNotebookSync
import SQLite3
import Testing
@testable import LingroveNotebookEngine

/// Real facade/SQLite/window/graph tests. Each case owns a disposable primary
/// database; failures compare durable rows as bytes, not just object counts.
@MainActor
struct LingroveNotebookApplyIntegrationTests {
    @Test("Empty first pulls persist remote metadata without committing a local corpus or invalidating a draft")
    func emptyPullsKeepRevisionZeroAndTheOriginalEditorBaseline() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let editor = try f.db.loadLingroveNotebook(workspaceId: f.workspaceID)
        let originalHeader = try f.allRows()["notebook_state"]
        for _ in 0..<2 {
            let proof = try f.window(VocabularyDocument(), initialized: false)
            let applied = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), now: Date())
            #expect(applied == editor)
            #expect(try f.allRows()["notebook_state"] == originalHeader)
            #expect(try !f.db.hasCommittedLingroveNotebook())
            try f.db.requireLingroveNotebookAccountMigrationSupport()
        }
        #expect(try f.db.core.scalarInt(sql: "SELECT revision FROM notebook_remote_state", values: []) == 2)
        #expect(try f.db.confirmedLingroveNotebookShadow(binding: f.binding)?.sequence.rawValue == "0")
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: editor, operationId: "editor-before-first-poll")
        #expect(saved.revision == 1)
        #expect(try f.db.hasCommittedLingroveNotebook())
    }



    @Test("Fresh unchanged windows preserve editor revision but still reject concurrent stale sync plans")
    func metadataOnlyPullsFenceSyncWithoutInvalidatingEditors() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let editor = try f.apply(Self.document())
        let header = try f.allRows()["notebook_state"]
        let first = try f.emptyDelta(sequence: "1"), second = try f.emptyDelta(sequence: "1")
        let firstPlan = try f.db.prepareLingroveNotebookApply(first, binding: f.binding, now: Date())
        let stale = try f.db.prepareLingroveNotebookApply(second, binding: f.binding, now: Date())
        #expect(try f.db.commitLingroveNotebookApply(firstPlan, now: Date()) == editor)
        #expect(try f.allRows()["notebook_state"] == header)
        let after = try f.allRows()
        #expect(throws: LingroveNotebookSyncStoreError.stalePreparation) { try f.db.commitLingroveNotebookApply(stale, now: Date()) }
        #expect(try f.allRows() == after)
        #expect(try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(second, binding: f.binding, now: Date()), now: Date()) == editor)
        #expect(try f.db.core.scalarInt(sql: "SELECT revision FROM notebook_remote_state", values: []) == 3)
        var edited = editor.document; edited.collections[0].note = "draft survived two polls"
        #expect(try f.db.saveLingroveNotebook(edited, basedOn: editor, operationId: "editor-before-idle-polls").revision == editor.revision + 1)
    }

    @Test("A Unicode byte-only remote edit advances the document revision and persists the exact text")
    func canonicalUnicodeEqualityDoesNotHideChangedRows() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        var original = Self.document(); original.collections[0].note = "caf\u{00E9}"
        let initial = try f.apply(original)
        var remote = original; remote.collections[0].note = "cafe\u{0301}"
        #expect(original == remote)
        let proof = try f.window(remote, previous: original)
        let result = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), now: Date())
        #expect(result.revision == initial.revision + 1)
        try f.reopen()
        let persisted = try f.db.loadLingroveNotebook(workspaceId: f.workspaceID)
        #expect(Data(persisted.document.collections[0].note.utf8) == Data(remote.collections[0].note.utf8))
    }

    @Test("Converged local intent retires atomically without receipts or releasing held review operations")
    func convergedJournalsRetireLocallyAndRollbackOnLateFailure() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: first,
            selection: .init(entryID: original.catalog[0].id, senseID: original.catalog[0].senses[0].id), intentId: UUID())
        _ = try f.db.enrollLingroveNotebookSense(draft)
        var changed = original; changed.collections[0].note = "temporary local edit"
        let edited = try f.db.saveLingroveNotebook(changed, basedOn: first, operationId: "converged-first")
        let restored = try f.db.saveLingroveNotebook(original, basedOn: edited, operationId: "converged-second")
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 2)
        let before = try f.allRows()
        try f.db.core.executeScript(sql: """
            CREATE TRIGGER fail_converged_retirement BEFORE DELETE ON notebook_pending_transactions
            WHEN OLD.operation_id='converged-second' BEGIN SELECT RAISE(ABORT,'converged-retirement-fixture'); END;
            """, errorContext: "Install local retirement fault")
        #expect(throws: (any Error).self) { try f.db.nextLingroveNotebookUpload(binding: f.binding) }
        #expect(try f.allRows() == before)
        try f.db.core.executeScript(sql: "DROP TRIGGER fail_converged_retirement;", errorContext: "Remove local retirement fault")
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding) == nil)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_pending_rows", values: []) == 0)
        let after = try f.allRows()
        #expect(after.filter { !$0.key.hasPrefix("notebook_pending_") } == before.filter { !$0.key.hasPrefix("notebook_pending_") })
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_receipts", values: []) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_held_card_operations", values: []) > 0)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspaceID) == restored)
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding) == nil)
    }

    @Test("Private Anki and timestamp-only edits remain on disk after their non-uploadable journals retire")
    func privateAndTimestampEditsNeedNoFabricatedServerReceipt() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        var original = Self.document()
        original.collections[0].review = .init(plan: .init(audioKinds: []))
        let first = try f.apply(original), sense = original.collections[0].senseID
        let anki = AnkiNoteBinding(originSenseID: sense, endpoint: "http://localhost:8765", profile: "private-retirement",
            noteID: 42, model: "Model", deck: "Deck", identityField: ReviewField.identity.rawValue,
            mapping: [.identity: ReviewField.identity.rawValue, .expression: "Expression", .meaning: "Meaning"],
            fields: [ReviewField.identity.rawValue: sense.uuidString.lowercased()])
        var local = first.document
        local.collections[0].review?.bindings = [anki]
        local.collections[0].review?.activeBindingID = anki.id
        local.catalog[0].updatedAt = local.catalog[0].updatedAt.addingTimeInterval(60)
        let saved = try f.db.saveLingroveNotebook(local, basedOn: first, operationId: "private-and-timestamp")
        #expect(try f.db.core.scalarInt(sql: "SELECT has_public_change FROM notebook_pending_transactions WHERE operation_id='private-and-timestamp'", values: []) == 0)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 1)
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding) == nil)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_receipts", values: []) == 0)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspaceID) == saved)
        let idle = try f.emptyDelta(sequence: "1")
        let after = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(idle, binding: f.binding, now: Date()), now: Date())
        #expect(after == saved)
        #expect(after.document.collections[0].review?.bindings == [anki])
    }

    @Test("Convergence after freezing cannot discard an unknown server outcome")
    func convergedCurrentDocumentStillRetainsItsFrozenRequest() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var local = original; local.collections[0].note = "might already be committed remotely"
        let saved = try f.db.saveLingroveNotebook(local, basedOn: first, operationId: "uncertain-before-convergence")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        _ = try f.db.saveLingroveNotebook(original, basedOn: saved, operationId: "converged-after-freeze")
        let before = try f.allRows()
        let retained = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(retained.body == pending.body)
        #expect(retained.frozenSHA256 == pending.frozenSHA256)
        #expect(try f.allRows() == before)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 2)
    }



    @Test("Apply preserves local book, pending edits and held review while advancing only the confirmed shadow")
    func applyRebasesPendingEditsAndPreservesReviewAcrossReopen() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document()
        let first = try f.apply(original)
        #expect(first.notebookId == f.localNotebookID)
        #expect(first.notebookId != f.scope.notebookID)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 0)
        let selection = VocabularySelection(entryID: original.catalog[0].id, senseID: original.catalog[0].senses[0].id)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: first, selection: selection, intentId: UUID())
        _ = try f.db.enrollLingroveNotebookSense(draft)
        let managedID = try f.db.core.scalarText(sql: "SELECT card_id FROM notebook_review_exercises LIMIT 1", values: [])
        _ = try f.db.submitReview(workspaceId: f.workspaceID, reviewSubmission: .init(cardId: managedID, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"))
        let ordinary = try f.db.saveCard(workspaceId: f.workspaceID,
            input: .init(frontText: "ordinary prompt", backText: "ordinary answer", tags: []), cardId: nil, mediaAssetIdsReadyForUpload: [])
        _ = try f.db.submitReview(workspaceId: f.workspaceID, reviewSubmission: .init(cardId: ordinary.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"))
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM review_events", values: []) == 2)
        var local = first.document
        local.collections[0].note = "local note\u{0000}"
        let edited = try f.db.saveLingroveNotebook(local, basedOn: first, operationId: "apply-local-note")
        let protected = try f.reviewProgressRows()
        var remote = original
        remote.collections[0].tags.append("remote tag")
        let proof = try f.window(remote, previous: original)
        let plan = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        let applied = try f.db.commitLingroveNotebookApply(plan, now: Date())
        #expect(applied.revision == edited.revision + 1)
        #expect(applied.document.collections[0].note == local.collections[0].note)
        #expect(applied.document.collections[0].tags == remote.collections[0].tags)
        #expect(try f.reviewProgressRows() == protected)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspaceID, cardId: managedID).tags == remote.collections[0].tags)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspaceID) == applied)
        #expect(try f.db.confirmedLingroveNotebookShadow(binding: f.binding)?.sequence.rawValue == "2")
        var later = applied.document; later.collections[0].note = "later local edit"
        let savedLater = try f.db.saveLingroveNotebook(later, basedOn: applied, operationId: "apply-later-note")
        let afterLater = try f.reviewProgressRows()
        #expect(try f.db.commitLingroveNotebookApply(plan, now: Date()) == savedLater)
        #expect(try f.reviewProgressRows() == afterLater)
    }

    @Test("Stale preparation rejects UI saves and concurrent apply; fresh preparation retains both edits")
    func staleApplyCannotOverwriteNewerLocalOrRemoteRevision() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var remote = original; remote.collections[0].note = "server note"
        let proof = try f.window(remote, previous: original)
        let stale = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        var local = first.document; local.catalog[0].senses[0].meaning = "locally revised meaning"
        let saved = try f.db.saveLingroveNotebook(local, basedOn: first, operationId: "apply-concurrent-local")
        let before = try f.allRows()
        #expect(throws: LingroveNotebookSyncStoreError.stalePreparation) { try f.db.commitLingroveNotebookApply(stale, now: Date()) }
        #expect(try f.allRows() == before)
        let fresh = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        let differentLease = try f.window(remote, previous: original)
        let concurrent = try f.db.prepareLingroveNotebookApply(differentLease, binding: f.binding, now: Date())
        let result = try f.db.commitLingroveNotebookApply(fresh, now: Date())
        #expect(result.document.catalog[0].senses[0].meaning == saved.document.catalog[0].senses[0].meaning)
        #expect(result.document.collections[0].note == remote.collections[0].note)
        let after = try f.allRows()
        #expect(throws: LingroveNotebookSyncStoreError.stalePreparation) { try f.db.commitLingroveNotebookApply(concurrent, now: Date()) }
        #expect(try f.allRows() == after)
    }

    @Test("Late SQL failure rolls back document, shadow, cursor and private remainder; the same plan can retry")
    func lateSQLFailureRollsBackTheWholeApply() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(); let initial = try f.apply(original)
        var remote = original; remote.collections[0].note = "remote transaction"
        let proof = try f.window(remote, previous: original)
        var conflicting = original; conflicting.collections[0].note = "local transaction"
        let local = try f.db.saveLingroveNotebook(conflicting, basedOn: initial, operationId: "conflicting-note")
        let conflictBefore = try f.allRows()
        #expect(throws: VocabularyWireRebaseError.self) { try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()) }
        #expect(try f.allRows().filter { $0.key != "notebook_sync_conflicts" } == conflictBefore.filter { $0.key != "notebook_sync_conflicts" })
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_sync_conflicts", values: []) == 1)
        _ = try f.db.saveLingroveNotebook(original, basedOn: local, operationId: "restore-local-note")
        let plan = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        let before = try f.allRows()
        try f.db.core.executeScript(sql: """
            CREATE TRIGGER fail_late_apply BEFORE UPDATE ON notebook_remote_records
            WHEN NEW.entity_type='notebookSettings' BEGIN SELECT RAISE(ABORT,'late-apply-fixture'); END;
            """, errorContext: "Could not install apply fault fixture")
        #expect(throws: (any Error).self) { try f.db.commitLingroveNotebookApply(plan, now: Date()) }
        #expect(try f.allRows() == before)
        #expect(try f.db.confirmedLingroveNotebookShadow(binding: f.binding)?.sequence.rawValue == "1")
        try f.db.core.executeScript(sql: "DROP TRIGGER fail_late_apply;", errorContext: "Could not remove apply fault fixture")
        #expect(try f.db.commitLingroveNotebookApply(plan, now: Date()).document == remote)
    }

    @Test("Expiry during SQL execution rolls back all earlier rows before commit")
    func leaseExpiryDuringSQLRollsBackApply() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(); _ = try f.apply(original)
        var remote = original; remote.collections[0].note = "expires during SQL"
        let proof = try f.window(remote, previous: original)
        let plan = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        let before = try f.allRows()
        var reached: Int32 = 0
        try withUnsafeMutablePointer(to: &reached) { flag in
            // SQLite borrows this pointer only during this synchronous test.
            // The callback executes on the committing thread; no pointer or
            // closure capturing test state escapes into a concurrent task.
            let result = sqlite3_create_function_v2(f.db.core.connection, "slow_apply_fixture", 0, SQLITE_UTF8, flag, { context, _, _ in
                guard let context, let raw = sqlite3_user_data(context) else { return }
                raw.assumingMemoryBound(to: Int32.self).pointee = 1
                Thread.sleep(forTimeInterval: 1.1)
                sqlite3_result_int(context, 1)
            }, nil, nil, nil)
            #expect(result == SQLITE_OK)
            defer {
                try? f.db.core.executeScript(sql: "DROP TRIGGER IF EXISTS slow_apply_trigger;", errorContext: "Remove slow apply fixture")
                sqlite3_create_function_v2(f.db.core.connection, "slow_apply_fixture", 0, SQLITE_UTF8, nil, nil, nil, nil, nil)
            }
            try f.db.core.executeScript(sql: """
                CREATE TRIGGER slow_apply_trigger BEFORE UPDATE ON notebook_state BEGIN SELECT slow_apply_fixture(); END;
                """, errorContext: "Install slow apply fixture")
            let lastSecond = Date(timeIntervalSince1970: Double(proof.manifest.expiresAtMilliseconds) / 1000 - 1)
            #expect(throws: VocabularyWireWindowError.expiredWindow) { try f.db.commitLingroveNotebookApply(plan, now: lastSecond) }
            #expect(flag.pointee == 1)
            #expect(try f.allRows() == before)
        }
        #expect(try f.db.commitLingroveNotebookApply(plan, now: Date()).document == remote)
    }









    @Test("Frozen uploads survive reopen, preserve post-send edits, and retire only their captured journals")
    func uploadReplayAndCoveredReceiptPreserveLaterEdits() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: first,
            selection: .init(entryID: original.catalog[0].id, senseID: original.catalog[0].senses[0].id), intentId: UUID())
        _ = try f.db.enrollLingroveNotebookSense(draft)
        let card = try f.db.core.scalarText(sql: "SELECT card_id FROM notebook_review_exercises LIMIT 1", values: [])
        _ = try f.db.submitReview(workspaceId: f.workspaceID, reviewSubmission: .init(cardId: card, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"))
        var sent = original; sent.collections[0].note = "sent note"; sent.collections[0].tags += ["b", "c"]
        let saved = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "upload-sent")
        let plainWindow = try f.window(original, previous: original)
        let plainPlan = try f.db.prepareLingroveNotebookApply(plainWindow, binding: f.binding, now: Date())
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(throws: LingroveNotebookSyncStoreError.stalePreparation) { try f.db.commitLingroveNotebookApply(plainPlan, now: Date()) }
        let protected = try f.reviewProgressRows()
        var later = sent; later.collections[0].note = "later note"; later.collections[0].tags.append("later tag")
        _ = try f.db.saveLingroveNotebook(later, basedOn: saved, operationId: "upload-later")
        try f.reopen()
        let replay = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(replay.body == pending.body); #expect(replay.frozenSHA256 == pending.frozenSHA256)
        var server = sent
        // c was already appended by a peer before our [b,c] request arrived.
        server.collections[0].tags = original.collections[0].tags + ["c", "b"]
        let proof = try f.window(server, previous: original)
        #expect(throws: LingroveNotebookUploadStoreError.awaitingReceipt) {
            try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        }
        let receipt = try Self.uploadReceipt(pending)
        try f.db.recordLingroveNotebookReceipt(receipt, bodySHA256: pending.bodySHA256, binding: f.binding)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 2)
        #expect(try f.db.confirmedLingroveNotebookShadow(binding: f.binding)?.sequence.rawValue == "1")
        try f.reopen()
        let plan = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        let applied = try f.db.commitLingroveNotebookApply(plan, now: Date())
        #expect(applied.document.collections[0].note == "later note")
        #expect(applied.document.collections[0].tags == original.collections[0].tags + ["c", "b", "later tag"])
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_pending_transactions WHERE operation_id='upload-sent'", values: []) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_pending_transactions WHERE operation_id='upload-later'", values: []) == 1)
        #expect(try f.reviewProgressRows() == protected)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspaceID, cardId: card).tags == applied.document.collections[0].tags)
        let next = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(next.batch.request.groupID != pending.batch.request.groupID)
        try f.db.recordLingroveNotebookReceipt(receipt, bodySHA256: pending.bodySHA256, binding: f.binding)
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding)?.body == next.body)
    }

    @Test("Malformed receipts and non-covering windows leave the frozen group and journals intact")
    func uploadRejectsPartialReceiptsAndFalseCoverage() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var sent = original; sent.collections[0].note = "sent"; sent.catalog[0].senses[0].meaning = "new meaning"
        _ = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "upload-two-members")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(pending.batch.request.members.count == 2)
        let before = try f.allRows()
        let partial = try Self.uploadReceipt(pending, members: Array(pending.batch.request.members.map(\.memberID).dropLast()))
        #expect(throws: VocabularyWireUploadError.receiptMismatch) {
            try f.db.recordLingroveNotebookReceipt(partial, bodySHA256: pending.bodySHA256, binding: f.binding)
        }
        let reversed = try Self.uploadReceipt(pending, members: Array(pending.batch.request.members.map(\.memberID).reversed()))
        #expect(throws: VocabularyWireUploadError.receiptMismatch) {
            try f.db.recordLingroveNotebookReceipt(reversed, bodySHA256: pending.bodySHA256, binding: f.binding)
        }
        let receipt = try Self.uploadReceipt(pending)
        #expect(throws: LingroveNotebookUploadStoreError.receiptConflict) {
            try f.db.recordLingroveNotebookReceipt(receipt, bodySHA256: String(repeating: "0", count: 64), binding: f.binding)
        }
        #expect(try f.allRows() == before)
        try f.db.recordLingroveNotebookReceipt(receipt, bodySHA256: pending.bodySHA256, binding: f.binding)
        let confirmed = try f.allRows()
        let missingMembers = try f.window(original, previous: original)
        #expect(throws: VocabularyWireUploadError.incompleteReceiptCoverage) {
            try f.db.prepareLingroveNotebookApply(missingMembers, binding: f.binding, now: Date())
        }
        #expect(try f.allRows() == confirmed)
    }

    @Test("Failure after journal retirement rolls back the receipt ledger, cursor, document and queue together")
    func uploadFinalizationFailureIsAtomicAndRetryable() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var sent = original; sent.collections[0].note = "sent transaction"
        _ = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "upload-atomic")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        let receipt = try Self.uploadReceipt(pending)
        try f.db.recordLingroveNotebookReceipt(receipt, bodySHA256: pending.bodySHA256, binding: f.binding)
        let proof = try f.window(sent, previous: original)
        let plan = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        let before = try f.allRows()
        try f.db.core.executeScript(sql: """
            CREATE TRIGGER fail_upload_retirement BEFORE DELETE ON notebook_upload_batches BEGIN SELECT RAISE(ABORT,'upload-retirement-fixture'); END;
            """, errorContext: "Install upload fault fixture")
        #expect(throws: (any Error).self) { try f.db.commitLingroveNotebookApply(plan, now: Date()) }
        #expect(try f.allRows() == before)
        try f.db.core.executeScript(sql: "DROP TRIGGER fail_upload_retirement;", errorContext: "Remove upload fault fixture")
        _ = try f.db.commitLingroveNotebookApply(plan, now: Date())
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 0)
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding) == nil)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_receipts", values: []) == 1)
        try f.db.recordLingroveNotebookReceipt(receipt, bodySHA256: pending.bodySHA256, binding: f.binding)
    }



    @Test("An uninitialized server receives explicit initial corpus creation while later local additions remain pending")
    func initialUploadAndLaterIndependentCreation() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let emptyProof = try f.window(VocabularyDocument(), initialized: false)
        let empty = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(emptyProof, binding: f.binding, now: Date()), now: Date())
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding) == nil)
        let original = Self.document()
        let saved = try f.db.saveLingroveNotebook(original, basedOn: empty, restoringBackup: true, operationId: "initial-upload")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(pending.batch.request.members.allSatisfy { if case .create = $0.change.action { return $0.change.baseVersion == .zero }; return false })
        var later = original
        let extra = VocabularyEntry(id: UUID(), expression: "afterward", dictionaryForm: "afterward", language: .english,
            kind: .word, senses: [], createdAt: Date(), updatedAt: Date())
        later.catalog.append(extra)
        _ = try f.db.saveLingroveNotebook(later, basedOn: saved, operationId: "after-initial-upload")
        let receipt = try Self.uploadReceipt(pending, sequence: "1")
        try f.db.recordLingroveNotebookReceipt(receipt, bodySHA256: pending.bodySHA256, binding: f.binding)
        let proof = try f.window(original)
        let applied = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), now: Date())
        #expect(applied.document.catalog.contains { $0.id == extra.id })
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_pending_transactions WHERE operation_id='initial-upload'", values: []) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_pending_transactions WHERE operation_id='after-initial-upload'", values: []) == 1)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_review_enrollments", values: []) == 0)
    }

    @Test("Cancellation persists the original bytes across reopen and accepts a commit that won the server race")
    func cancellationIntentSurvivesReopenWithoutInventingAnOutcome() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var sent = original; sent.collections[0].note = "cancel uncertain request"
        _ = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "cancel-intent")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        let protected = try f.protectedRows()
        try f.db.requestLingroveNotebookUploadCancellation(groupID: pending.batch.request.groupID, bodySHA256: pending.bodySHA256, binding: f.binding)
        try f.reopen()
        let replay = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(replay.cancelRequested); #expect(replay.outcome == nil)
        #expect(replay.body == pending.body); #expect(replay.frozenSHA256 == pending.frozenSHA256)
        #expect(try f.protectedRows() == protected)
        let receipt = try Self.uploadReceipt(pending)
        try f.db.recordLingroveNotebookOutcome(.committed(receipt), bodySHA256: pending.bodySHA256, binding: f.binding)
        let before = try f.allRows()
        #expect(throws: LingroveNotebookUploadStoreError.receiptConflict) {
            try f.db.recordLingroveNotebookOutcome(.rejected(Self.uploadRejection(pending)), bodySHA256: pending.bodySHA256, binding: f.binding)
        }
        #expect(try f.allRows() == before)
        let proof = try f.window(sent, previous: original)
        let applied = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), now: Date())
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_terminal_state", values: []) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_receipts", values: []) == 1)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 0)
        var later = applied.document; later.collections[0].tags.append("new batch after committed cancellation race")
        _ = try f.db.saveLingroveNotebook(later, basedOn: applied, operationId: "after-cancel-race")
        let next = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding)), completed = try f.allRows()
        #expect(throws: LingroveNotebookUploadStoreError.receiptConflict) {
            try f.db.recordLingroveNotebookOutcome(.rejected(Self.uploadRejection(pending)), bodySHA256: pending.bodySHA256, binding: f.binding)
        }
        #expect(try f.allRows() == completed)
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding)?.body == next.body)
    }

    @Test("A negative result settles against the already applied window without retiring journals or later edits")
    func rejectionCanSettleTheSameManifestAndReplayAfterANewerBatch() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), proof = try f.window(original)
        let first = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), now: Date())
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: first,
            selection: .init(entryID: original.catalog[0].id, senseID: original.catalog[0].senses[0].id), intentId: UUID())
        _ = try f.db.enrollLingroveNotebookSense(draft)
        let managed = try f.db.core.scalarText(sql: "SELECT card_id FROM notebook_review_exercises LIMIT 1", values: [])
        _ = try f.db.submitReview(workspaceId: f.workspaceID, reviewSubmission: .init(cardId: managed, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"))
        let ordinary = try f.db.saveCard(workspaceId: f.workspaceID,
            input: .init(frontText: "ordinary prompt", backText: "ordinary answer", tags: []), cardId: nil, mediaAssetIdsReadyForUpload: [])
        _ = try f.db.submitReview(workspaceId: f.workspaceID, reviewSubmission: .init(cardId: ordinary.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"))
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM review_events", values: []) == 2)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_held_card_operations", values: []) > 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM outbox", values: []) > 0)
        var sent = original; sent.collections[0].note = "not committed"
        let saved = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "rejected-original")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        var later = sent; later.collections[0].tags.append("after rejection request")
        _ = try f.db.saveLingroveNotebook(later, basedOn: saved, operationId: "rejected-later")
        let rejection = try Self.uploadRejection(pending)
        try f.db.recordLingroveNotebookOutcome(.rejected(rejection), bodySHA256: pending.bodySHA256, binding: f.binding)
        let protected = try f.protectedRows()
        try f.reopen()
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding)?.rejection == rejection)
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding)?.body == pending.body)
        let plan = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date())
        let applied = try f.db.commitLingroveNotebookApply(plan, now: Date())
        #expect(applied.document == later)
        #expect(try f.protectedRows() == protected)
        #expect(try f.db.confirmedLingroveNotebookShadow(binding: f.binding)?.sequence.rawValue == "1")
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_batches", values: []) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_rejections", values: []) == 1)
        let next = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(next.batch.request.groupID != pending.batch.request.groupID)
        try f.db.recordLingroveNotebookOutcome(.rejected(rejection), bodySHA256: pending.bodySHA256, binding: f.binding)
        #expect(try f.db.commitLingroveNotebookApply(plan, now: Date()) == applied)
        #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding)?.body == next.body)
        #expect(throws: LingroveNotebookUploadStoreError.receiptConflict) {
            try f.db.recordLingroveNotebookReceipt(Self.uploadReceipt(pending), bodySHA256: pending.bodySHA256, binding: f.binding)
        }
    }

    @Test("A terminal conflict retains frozen evidence until the user resolves the conflicting field")
    func rejectedGroupStillRequiresAnExplicitConflictResolution() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var local = original; local.collections[0].note = "mine"
        let edited = try f.db.saveLingroveNotebook(local, basedOn: first, operationId: "terminal-conflict")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        try f.db.recordLingroveNotebookOutcome(.rejected(Self.uploadRejection(pending, reason: "entity_conflict")), bodySHA256: pending.bodySHA256, binding: f.binding)
        var remote = original; remote.collections[0].note = "remote"
        let proof = try f.window(remote, previous: original), before = try f.allRows()
        #expect(throws: VocabularyWireRebaseError.self) { try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()) }
        #expect(try f.allRows().filter { $0.key != "notebook_sync_conflicts" } == before.filter { $0.key != "notebook_sync_conflicts" })
        // An explicit local edit can also converge with the account value.
        // The sync layer still cannot choose it or erase pending journals.
        var resolved = edited.document; resolved.collections[0].note = remote.collections[0].note
        _ = try f.db.saveLingroveNotebook(resolved, basedOn: edited, operationId: "accept-server-field")
        let protected = try f.protectedRows()
        let applied = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), now: Date())
        #expect(applied.document.collections[0].note == "remote")
        #expect(try f.protectedRows() == protected)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_rejections", values: []) == 1)
    }

    @Test("Invalid-corpus decisions block unchanged intent durably and explicit retry is fenced and consumed with freeze")
    func invalidCorpusRetrySurvivesRestartAndFreezeRollback() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var changed = original; changed.collections[0].note = "rejected public intent"
        _ = try f.db.saveLingroveNotebook(changed, basedOn: first, operationId: "rejected-persistent")
        let frozen = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        try f.db.recordLingroveNotebookOutcome(.rejected(Self.uploadRejection(frozen, reason: "invalid_corpus")),
            bodySHA256: frozen.bodySHA256, binding: f.binding)
        let proof = try f.window(original, previous: original)
        _ = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), now: Date())
        try f.reopen()
        #expect(throws: LingroveNotebookUploadStoreError.rejectedIntent) { try f.db.nextLingroveNotebookUpload(binding: f.binding) }
        let current = try f.db.loadLingroveNotebook(workspaceId: f.workspaceID)
        var timestamp = current.document; timestamp.catalog[0].updatedAt = timestamp.catalog[0].updatedAt.addingTimeInterval(1)
        _ = try f.db.saveLingroveNotebook(timestamp, basedOn: current, operationId: "rejection-timestamp-only")
        #expect(throws: LingroveNotebookUploadStoreError.rejectedIntent) { try f.db.nextLingroveNotebookUpload(binding: f.binding) }
        let stale = try #require(try LingroveNotebookRetryStore(core: f.db.core).captureKnown(f.binding))
        try f.link(owner: "other-account"); try f.link(owner: f.scope.ownerUserID)
        #expect(throws: LingroveNotebookWindowStoreError.bindingChanged) { try LingroveNotebookRetryStore(core: f.db.core).authorize(stale) }
        f.binding = try f.db.captureLingroveNotebookWindowBinding(scope: f.scope)
        let retry = try #require(try LingroveNotebookRetryStore(core: f.db.core).captureKnown(f.binding))
        try LingroveNotebookRetryStore(core: f.db.core).authorize(retry)
        try f.db.core.executeScript(sql: "CREATE TRIGGER reject_retry_freeze BEFORE INSERT ON notebook_upload_batches BEGIN SELECT RAISE(ABORT,'retry-freeze-rollback'); END;",
            errorContext: "Install retry freeze rollback")
        #expect(throws: (any Error).self) { try f.db.nextLingroveNotebookUpload(binding: f.binding) }
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_sync_rejections", values: []) == 1)
        try f.db.core.executeScript(sql: "DROP TRIGGER reject_retry_freeze;", errorContext: "Remove retry freeze rollback")
        try f.reopen()
        let next = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        #expect(next.batch.request.groupID != frozen.batch.request.groupID)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_sync_rejections", values: []) == 0)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 2)
    }

    @Test("Late rejection finalization failure rolls back the ledger, frozen body, shadow and document together")
    func rejectionFinalizationFailurePreservesAllPendingWork() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var sent = original; sent.collections[0].note = "rejected transaction"
        _ = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "rejection-atomic")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding))
        try f.db.recordLingroveNotebookOutcome(.rejected(Self.uploadRejection(pending)), bodySHA256: pending.bodySHA256, binding: f.binding)
        let proof = try f.emptyDelta(sequence: "1")
        let plan = try f.db.prepareLingroveNotebookApply(proof, binding: f.binding, now: Date()), before = try f.allRows()
        try f.db.core.executeScript(sql: """
            CREATE TRIGGER fail_rejection_retirement BEFORE DELETE ON notebook_upload_batches BEGIN SELECT RAISE(ABORT,'rejection-retirement-fixture'); END;
            """, errorContext: "Install negative finalization fault")
        #expect(throws: (any Error).self) { try f.db.commitLingroveNotebookApply(plan, now: Date()) }
        #expect(try f.allRows() == before)
        try f.db.core.executeScript(sql: "DROP TRIGGER fail_rejection_retirement;", errorContext: "Remove negative finalization fault")
        let result = try f.db.commitLingroveNotebookApply(plan, now: Date())
        #expect(result.document.collections[0].note == "rejected transaction")
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 1)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_rejections", values: []) == 1)
    }

    @Test("Outcome callbacks match full coverage, original bytes and account generation before persistence")
    func rejectionCallbacksRejectMismatchesAndStaleGenerations() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var sent = original; sent.collections[0].note = "pending"; sent.catalog[0].senses[0].meaning = "pending meaning"
        _ = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "terminal-identity")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding)), before = try f.allRows()
        let partial = try Self.uploadRejection(pending, members: [pending.batch.request.members[0].memberID])
        #expect(throws: VocabularyWireUploadError.receiptMismatch) { try f.db.recordLingroveNotebookOutcome(.rejected(partial), bodySHA256: pending.bodySHA256, binding: f.binding) }
        let rejection = try Self.uploadRejection(pending)
        #expect(throws: LingroveNotebookUploadStoreError.receiptConflict) { try f.db.recordLingroveNotebookOutcome(.rejected(rejection), bodySHA256: String(repeating: "0", count: 64), binding: f.binding) }
        #expect(throws: LingroveNotebookUploadStoreError.receiptConflict) { try f.db.requestLingroveNotebookUploadCancellation(groupID: UUID(), bodySHA256: pending.bodySHA256, binding: f.binding) }
        #expect(try f.allRows() == before)
        let old = f.binding
        try f.link(owner: "another-owner"); try f.link(owner: f.scope.ownerUserID)
        #expect(throws: LingroveNotebookWindowStoreError.bindingChanged) { try f.db.recordLingroveNotebookOutcome(.rejected(rejection), bodySHA256: pending.bodySHA256, binding: old) }
        #expect(throws: LingroveNotebookWindowStoreError.bindingChanged) { try f.db.requestLingroveNotebookUploadCancellation(groupID: pending.batch.request.groupID, bodySHA256: pending.bodySHA256, binding: old) }
        f.binding = try f.db.captureLingroveNotebookWindowBinding(scope: f.scope)
        try f.db.recordLingroveNotebookOutcome(.rejected(rejection), bodySHA256: pending.bodySHA256, binding: f.binding)
        let confirmed = try f.allRows()
        #expect(throws: LingroveNotebookUploadStoreError.receiptConflict) { try f.db.recordLingroveNotebookReceipt(Self.uploadReceipt(pending), bodySHA256: pending.bodySHA256, binding: f.binding) }
        #expect(try f.allRows() == confirmed)
        try f.db.close()
        #expect(throws: (any Error).self) { try f.db.recordLingroveNotebookOutcome(.rejected(rejection), bodySHA256: pending.bodySHA256, binding: f.binding) }
        try f.reopen()
        #expect(try f.allRows() == confirmed)
    }







    @Test("Cancel during closure rebase rejects the stale plan; new user work clears the durable gate only atomically")
    func closureRebaseCancellationAndNewIntent() throws {
        for converged in [false,true] {
            let f = try ApplyFixture(); defer { f.cleanUp() }
            let original = Self.document(), first = try f.apply(original)
            var sent = original; sent.collections[0].note = "expired but then cancelled"
            _ = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "closure-race")
            let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding, transport: .staged))
            let manifest = try Self.uploadClosureManifest(pending, state: "expired")
            try f.db.recordLingroveNotebookUploadClosure(manifest, pending: pending, binding: f.binding)
            let window = try f.emptyDelta(sequence: "1")
            let plan = try f.db.prepareLingroveNotebookApply(window, binding: f.binding, now: Date())
            try f.db.requestLingroveNotebookUploadCancellation(groupID: pending.batch.request.groupID, bodySHA256: pending.bodySHA256, binding: f.binding)
            let cancelledRows = try f.allRows()
            #expect(throws: LingroveNotebookSyncStoreError.stalePreparation) { try f.db.commitLingroveNotebookApply(plan, now: Date()) }
            #expect(try f.allRows() == cancelledRows)
            let fresh = try f.db.prepareLingroveNotebookApply(window, binding: f.binding, now: Date())
            try f.db.core.executeScript(sql: "CREATE TRIGGER closure_retire_fault BEFORE DELETE ON notebook_upload_batches BEGIN SELECT RAISE(ABORT,'closure-final-delete'); END;",
                errorContext: "Install closure retirement fault")
            #expect(throws: (any Error).self) { try f.db.commitLingroveNotebookApply(fresh, now: Date()) }
            #expect(try f.allRows() == cancelledRows)
            try f.db.core.executeScript(sql: "DROP TRIGGER closure_retire_fault;", errorContext: "Remove closure retirement fault")
            let applied = try f.db.commitLingroveNotebookApply(fresh, now: Date())
            #expect(applied.document.collections[0].note == sent.collections[0].note)
            #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 1)
            #expect(try f.db.core.scalarInt(sql: "SELECT retry_blocked FROM notebook_completed_upload_closures", values: []) == 1)
            try f.reopen()
            #expect(throws: LingroveNotebookUploadStoreError.cancelledUpload) { try f.db.nextLingroveNotebookUpload(binding: f.binding) }
            _ = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(f.emptyDelta(sequence: "1"), binding: f.binding, now: Date()), now: Date())
            #expect(throws: LingroveNotebookUploadStoreError.cancelledUpload) { try f.db.nextLingroveNotebookUpload(binding: f.binding) }
            let privateBase = try f.db.loadLingroveNotebook(workspaceId: f.workspaceID)
            var privateEdit = privateBase.document; privateEdit.catalog[0].updatedAt = privateEdit.catalog[0].updatedAt.addingTimeInterval(60)
            _ = try f.db.saveLingroveNotebook(privateEdit, basedOn: privateBase, operationId: "timestamp-does-not-resume")
            #expect(try f.db.core.scalarInt(sql: "SELECT has_public_change FROM notebook_pending_transactions WHERE operation_id='timestamp-does-not-resume'", values: []) == 0)
            #expect(throws: LingroveNotebookUploadStoreError.cancelledUpload) { try f.db.nextLingroveNotebookUpload(binding: f.binding) }
            let current = try f.db.loadLingroveNotebook(workspaceId: f.workspaceID)
            var edited = current.document; edited.collections[0].note = converged ? original.collections[0].note : "new authorized edit"
            _ = try f.db.saveLingroveNotebook(edited, basedOn: current, operationId: "new-intent")
            if converged {
                #expect(try f.db.nextLingroveNotebookUpload(binding: f.binding, transport: .staged) == nil)
                #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 0)
            } else {
                let rows = try f.allRows()
                try f.db.core.executeScript(sql: "CREATE TRIGGER closure_freeze_fault BEFORE INSERT ON notebook_upload_batches BEGIN SELECT RAISE(ABORT,'closure-freeze-fault'); END;",
                    errorContext: "Install fresh freeze fault")
                #expect(throws: (any Error).self) { try f.db.nextLingroveNotebookUpload(binding: f.binding, transport: .staged) }
                #expect(try f.allRows() == rows)
                try f.db.core.executeScript(sql: "DROP TRIGGER closure_freeze_fault;", errorContext: "Remove fresh freeze fault")
                let next = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding, transport: .staged))
                #expect(next.batch.request.groupID != pending.batch.request.groupID)
            }
            #expect(try f.db.core.scalarInt(sql: "SELECT retry_blocked FROM notebook_completed_upload_closures", values: []) == 0)
        }
    }

    @Test("An external abort without local cancellation preserves journals and permits a fresh identity")
    func externalAbortIsNotUserCancellation() throws {
        let f = try ApplyFixture(); defer { f.cleanUp() }
        let original = Self.document(), first = try f.apply(original)
        var sent = original; sent.collections[0].note = "external abort"
        _ = try f.db.saveLingroveNotebook(sent, basedOn: first, operationId: "external-abort")
        let pending = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding, transport: .staged))
        try f.db.recordLingroveNotebookUploadClosure(Self.uploadClosureManifest(pending, state: "aborted"), pending: pending, binding: f.binding)
        _ = try f.db.commitLingroveNotebookApply(f.db.prepareLingroveNotebookApply(f.emptyDelta(sequence: "1"), binding: f.binding, now: Date()), now: Date())
        #expect(try f.db.core.scalarInt(sql: "SELECT retry_blocked FROM notebook_completed_upload_closures", values: []) == 0)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspaceID) == 1)
        let next = try #require(try f.db.nextLingroveNotebookUpload(binding: f.binding, transport: .staged))
        #expect(next.batch.request.groupID != pending.batch.request.groupID)
    }











    private static func uploadClosureManifest(_ pending: LingroveNotebookPendingUpload, state: String) throws -> VocabularyWireStagedManifest {
        let upload = try #require(pending.stagedUpload), scope = pending.batch.scope
        let json: [String: Any] = ["protocolVersion":1,"workspaceId":scope.workspaceID.uuidString.lowercased(),"notebookId":scope.notebookID.uuidString.lowercased(),
            "replicaId":scope.replicaID.uuidString.lowercased(),"groupId":pending.batch.request.groupID.uuidString.lowercased(),"bodySha256":upload.bodySHA256,
            "descriptorSha256":upload.descriptorSHA256,"byteCount":upload.body.count,"memberCount":pending.batch.request.members.count,
            "chunkCount":upload.chunkCount,"chunkBytes":VocabularyWireStagedLimits.chunkBytes,"state":state,"receivedOrdinals":[],"payloadRetired":state != "open",
            "createdAt":"2026-10-31T00:00:00.000Z","expiresAt":"2026-10-31T00:15:00.000Z"]
        return try JSONDecoder().decode(VocabularyWireStagedManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func uploadRejection(_ pending: LingroveNotebookPendingUpload, reason: String = "cancelled", members: [UUID]? = nil) throws -> VocabularyWireGroupRejection {
        let request = pending.batch.request
        let json: [String: Any] = ["protocolVersion":1,"notebookId":request.notebookID.uuidString.lowercased(),
            "groupId":request.groupID.uuidString.lowercased(),"memberIds":(members ?? request.members.map(\.memberID)).map { $0.uuidString.lowercased() },"reason":reason]
        return try JSONDecoder().decode(VocabularyWireGroupRejection.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func uploadReceipt(_ pending: LingroveNotebookPendingUpload, sequence: String = "2", members: [UUID]? = nil) throws -> VocabularyWireGroupReceipt {
        let request = pending.batch.request
        let json: [String: Any] = ["protocolVersion":1,"notebookId":request.notebookID.uuidString.lowercased(),
            "groupId":request.groupID.uuidString.lowercased(),"committedSequence":sequence,
            "memberIds":(members ?? request.members.map(\.memberID)).map { $0.uuidString.lowercased() }]
        return try JSONDecoder().decode(VocabularyWireGroupReceipt.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func document() -> VocabularyDocument {
        let now = Date(timeIntervalSinceReferenceDate: 811_111_111)
        let sense = VocabularySense(id: UUID(), meaning: "to retain", meaningLanguage: .english, meaningOrigin: .user,
            note: "initial note", tags: ["initial"], isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        return .init(entries: [
            .init(id: UUID(), expression: "keep", dictionaryForm: "keep", language: .english, kind: .word, senses: [sense], createdAt: now, updatedAt: now),
            .init(id: UUID(), expression: "independent", dictionaryForm: "independent", language: nil, kind: .word, senses: [], createdAt: now, updatedAt: now)
        ])
    }
}

/// Test-owned connection, scope and byte-page fixture. These helpers exercise the
/// same staging facade before returning the immutable proof to the apply writer.
@MainActor
private final class ApplyFixture {
    let directory: URL
    let url: URL
    var db: LocalDatabase
    let scope: VocabularyWireWindowScope
    var binding: LingroveNotebookWindowBinding
    let localNotebookID: UUID
    var workspaceID: String { scope.workspaceID.uuidString.lowercased() }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-apply-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("primary.sqlite")
        let database = try LocalDatabase(databaseURL: url)
        let workspace = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let local = try database.loadLingroveNotebook(workspaceId: workspace)
        let scope = VocabularyWireWindowScope(ownerUserID: "apply-owner", workspaceID: try #require(UUID(uuidString: workspace)), notebookID: UUID(), replicaID: UUID())
        try database.updateCloudSettings(cloudState: .linked, linkedUserId: scope.ownerUserID, linkedWorkspaceId: workspace,
            activeWorkspaceId: workspace, linkedEmail: "apply@example.test")
        self.db = database; self.scope = scope; localNotebookID = local.notebookId
        binding = try database.captureLingroveNotebookWindowBinding(scope: scope)
    }
    func link(owner: String) throws {
        try db.updateCloudSettings(cloudState: .linked, linkedUserId: owner, linkedWorkspaceId: workspaceID,
            activeWorkspaceId: workspaceID, linkedEmail: "apply@example.test")
    }
    func reopen() throws { try db.close(); db = try LocalDatabase(databaseURL: url) }
    func cleanUp() { try? db.close(); try? FileManager.default.removeItem(at: directory) }
    func apply(_ document: VocabularyDocument) throws -> LingroveNotebookSnapshot {
        let proof = try window(document)
        do { return try db.commitLingroveNotebookApply(db.prepareLingroveNotebookApply(proof, binding: binding, now: Date()), now: Date()) }
        catch LingroveNotebookAccountError.ownershipRequired {
            // This helper arranges an explicitly adopted baseline for unrelated
            // apply tests. Ownership behavior itself uses prepare directly.
            let account = LingroveNotebookAccountStore(core: db.core)
            let proposal = try #require(try db.core.inReadTransaction { try account.firstConnectionInTransaction(binding: binding) })
            try account.resolveFirst(proposal, merge: true)
            return try db.commitLingroveNotebookApply(db.prepareLingroveNotebookApply(proof, binding: binding, now: Date()), now: Date())
        }
    }
    func emptyDelta(sequence: String) throws -> VocabularyWireVerifiedWindow {
        try verified(WindowFixture.make(recordsJSON: Data("[]".utf8), recordCount: 0, scope: scope, initialized: true,
            mode: "incremental", afterSequence: sequence, highWaterSequence: sequence), binding: binding)
    }
    func window(_ document: VocabularyDocument, previous: VocabularyDocument? = nil, initialized: Bool = true,
                scope override: VocabularyWireWindowScope? = nil, binding ticket: LingroveNotebookWindowBinding? = nil) throws -> VocabularyWireVerifiedWindow {
        let scope = override ?? self.scope, activeBinding = ticket ?? self.binding
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func entities(_ document: VocabularyDocument) throws -> [String: VocabularyWireEntity] {
            let values = try VocabularyWireProjectionCodec.project(document, notebookID: scope.notebookID).entities
            return Dictionary(uniqueKeysWithValues: values.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
        }
        let next = try entities(document), old = try previous.map(entities) ?? [:]
        var records: [[String: Any]] = []
        if initialized {
            for key in Set(next.keys).union(old.keys).sorted() {
                if let e = next[key] {
                    let changes = try e.fields.keys.filter { try encoder.encode(e.fields[$0]) != encoder.encode(old[key]?.fields[$0]) }
                    if previous != nil && changes.isEmpty { continue }
                    let version = previous == nil ? "1" : "2"
                    var clocks = Dictionary(uniqueKeysWithValues: e.fields.keys.map { ($0, "1") }), resets = clocks
                    for field in changes { clocks[field] = version; resets[field] = version }
                    // This fixture only adds tags; all other changed fields are replacements.
                    if previous != nil, changes.contains("tags") { resets["tags"] = "1" }
                    records.append(["entityType":e.entityType.rawValue,"entityId":e.entityID,"version":version,"deleted":false,
                        "fields":try JSONSerialization.jsonObject(with: encoder.encode(e.fields)),"fieldVersions":clocks,"fieldResets":resets])
                } else if let e = old[key] {
                    records.append(["entityType":e.entityType.rawValue,"entityId":e.entityID,"version":"2","deleted":true,
                        "fields":[:],"fieldVersions":[:],"fieldResets":[:]])
                }
            }
        }
        let fixture = try WindowFixture.make(recordsJSON: JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]),
            recordCount: records.count, scope: scope, initialized: initialized, mode: previous == nil ? "bootstrap" : "incremental",
            afterSequence: previous == nil ? nil : "1", highWaterSequence: initialized ? (previous == nil ? "1" : "2") : "0")
        return try verified(fixture, binding: activeBinding)
    }
    private func verified(_ fixture: WindowFixture, binding: LingroveNotebookWindowBinding) throws -> VocabularyWireVerifiedWindow {
        _ = try db.beginLingroveNotebookWindow(fixture.manifest, binding: binding, now: Date())
        for page in fixture.pages { try db.receiveLingroveNotebookWindowPage(page, binding: binding, manifestSHA256: fixture.manifest.manifestSHA256, now: Date()) }
        let proof = try db.completeLingroveNotebookWindow(binding: binding, windowID: fixture.manifest.windowID,
            manifestSHA256: fixture.manifest.manifestSHA256, now: Date())
        try db.discardLingroveNotebookWindow(binding: binding, windowID: fixture.manifest.windowID)
        return proof
    }
    /// A committed source edit refreshes generated faces/link journals. Progress remains
    /// independent: compare scheduler snapshots, immutable events and enrollment ownership.
    func reviewProgressRows() throws -> [String: [Data]] {
        var result = try rows(tables: ["review_events", "notebook_review_enrollments", "notebook_review_exercises",
            "notebook_review_requests", "notebook_card_sync_holds", "notebook_review_schedule_heads"])
        result["cardProgress"] = try db.loadActiveCards(workspaceId: workspaceID).sorted { $0.cardId < $1.cardId }.map(notebookReviewProgressEvidence)
        return result
    }
    func protectedRows() throws -> [String: [Data]] {
        try rows(tables: ["cards","review_events","notebook_card_links","notebook_card_link_operations","notebook_card_sync_holds",
            "notebook_held_card_operations","notebook_review_enrollments","notebook_review_exercises","notebook_review_operations",
            "notebook_review_requests","notebook_pending_transactions","notebook_pending_rows","outbox","sync_state",
            "media_assets","media_blob_cache","media_transfer_queue"])
    }
    func allRows() throws -> [String: [Data]] {
        var result = try protectedRows()
        let tableNames = try db.core.query(sql: "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'notebook_%' AND name NOT LIKE 'notebook_download_%' AND name<>'notebook_window_binding' ORDER BY name", values: []) { DatabaseCore.columnText(statement: $0, index: 0) }
        for (key, value) in try rows(tables: tableNames) { result[key] = value }
        return result
    }
    private func rows(tables: [String]) throws -> [String: [Data]] {
        var result: [String: [Data]] = [:]
        for table in tables {
            result[table] = try db.core.query(sql: "SELECT * FROM \(table) ORDER BY rowid", values: []) { statement in
                let columns = (0..<sqlite3_column_count(statement)).map { index -> String in
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_NULL: "null"
                    case SQLITE_INTEGER: "i:" + String(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT: "r:" + String(sqlite3_column_double(statement, index).bitPattern)
                    default: "t:" + DatabaseCore.columnText(statement: statement, index: index)
                    }
                }
                return try JSONEncoder().encode(columns)
            }
        }
        return result
    }
}
