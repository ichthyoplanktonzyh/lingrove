import Foundation
import LingroveNotebook
import LingroveNotebookSync
import Testing
@testable import LingroveNotebookEngine

/// These synthetic databases exercise the complete material transaction rather than a renderer
/// mock: source follow, manual ownership, immutable rating history, scoped bytes and exact ACKs.
@MainActor
struct ReviewMaterialIntegrationTests {
    @Test func richPlanReopensAndFollowsSourcesWithoutReplacingAuthoredFacesOrRatings() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        var document = Self.document()
        var entries = document.entries
        entries[0].senses[0].content = [.init(content: .image(image.reference, caption: "source caption"))]
        document.entries = entries
        let saved = try f.db.saveLingroveNotebook(document, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace),
            images: [image.reference.filename: image.data])
        let entry = saved.document.entries[0], sense = entry.senses[0]
        let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
        let audio = Self.audio(text: entry.expression)
        let plan = ReviewMaterialPlan(name: "Rich", layout: .init(front: [.init(source: .expression)],
            back: [.init(source: .meaning), .init(source: .notes), .init(source: .senseImage, blockID: sense.content?.first?.id, showCaption: true),
                   .init(source: .expressionAudio), .init(source: .custom, content: [.init(content: .text(.init(text: "owned *text*")))])]), audio: [.expression: audio.receipt])
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection, materialPlan: plan)
        let initial = try f.db.loadBuiltInNotebookReview(scope: saved, now: Date())
        _ = try f.db.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, media: [audio.prepared], action: .init(content: initial, selection: selection))
        let link = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first)
        var card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: link.cardId)
        #expect(link.materialPlan == plan)
        #expect(card.backText.contains(#"owned \*text\*"#))
        #expect(managedMediaAssetIdsReferencedInMarkdown(text: card.backText).count == 2)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_review_media", values: []) == 2)
        card = try f.db.saveCard(workspaceId: f.workspace, input: .init(frontText: "my authored prompt", backText: card.backText, tags: card.tags), cardId: card.cardId, mediaAssetIdsReadyForUpload: [])
        card = try f.db.submitReview(workspaceId: f.workspace, reviewSubmission: .init(cardId: card.cardId, rating: .good,
            reviewedAtClient: "2026-11-03T03:00:00.000Z", reviewedTimeZone: "UTC"))
        var changed = saved.document; entries = changed.entries
        entries[0].senses[0].meaning = "new meaning"; entries[0].senses[0].note = "new note"; changed.entries = entries
        let refreshed = try f.db.saveLingroveNotebook(changed, basedOn: saved)
        let updated = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId)
        #expect(updated.frontText == "my authored prompt")
        #expect(updated.backText.contains("new meaning") && updated.backText.contains("new note"))
        #expect(updated.reps == card.reps && updated.dueAt == card.dueAt)
        #expect(try f.db.cardStore.loadReviewEvents(workspaceId: f.workspace).count == 1)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first?.materialPlan == plan)
        #expect(try LingroveNotebookReviewMediaStore(core: f.db.core).media(reference: audio.prepared.reference, workspaceID: f.workspace) == audio.prepared)
        let removed = try f.db.saveLingroveNotebook(VocabularyDocument(), basedOn: refreshed, restoringBackup: true)
        let unavailable = try f.db.loadBuiltInNotebookReview(scope: removed, now: Date())
        #expect(!unavailable.eligibleCardIDs.contains(card.cardId))
        let retainedLink = try #require(unavailable.review.links.first)
        let retainedCard = try #require(unavailable.review.groups[sense.id]?.cards.first)
        try f.db.retainNotebookExercise(link: retainedLink, card: retainedCard, snapshot: removed,
            action: .init(content: unavailable, selection: selection))
        let retained = try f.db.loadBuiltInNotebookReview(scope: removed, now: Date())
        var renamed = plan; renamed.name = "Retained rich"
        try f.db.saveRetainedBuiltInNotebookMaterial(link: try #require(retained.review.links.first), card: retainedCard,
            input: .init(frontText: retainedCard.frontText, backText: retainedCard.backText, tags: retainedCard.tags),
            materialPlan: renamed, action: .init(content: retained, selection: selection))
        #expect(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first?.materialPlan == renamed)
        #expect(try f.db.cardStore.loadReviewEvents(workspaceId: f.workspace).count == 1)
    }

    @Test func mediaAndEnrollmentRollBackTogetherAndIntentReplayDoesNotWrite() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let entry = saved.document.entries[0], sense = entry.senses[0]
        let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
        let audio = Self.audio(text: entry.expression)
        let plan = ReviewMaterialPlan(layout: .init(front: [.init(source: .expressionAudio)], back: [.init(source: .meaning)]), audio: [.expression: audio.receipt])
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection, materialPlan: plan)
        let content = try f.db.loadBuiltInNotebookReview(scope: saved, now: Date())
        let action = NotebookBuiltInReviewAction(content: content, selection: selection)
        try f.db.core.executeScript(sql: "CREATE TRIGGER reject_rich_link BEFORE INSERT ON notebook_card_links BEGIN SELECT RAISE(ABORT,'forced rollback'); END;", errorContext: "Synthetic failure")
        #expect(throws: (any Error).self) { try f.db.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, media: [audio.prepared], action: action) }
        for table in ["cards", "notebook_review_media", "notebook_card_links", "notebook_review_enrollments"] {
            #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM " + table, values: []) == 0)
        }
        try f.db.core.executeScript(sql: "DROP TRIGGER reject_rich_link;", errorContext: "Remove synthetic failure")
        let bad = ReviewMaterialPreparedMedia(reference: audio.prepared.reference, data: Data("wrong".utf8))
        #expect(throws: (any Error).self) { try f.db.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, media: [bad], action: action) }
        let malformed = Self.oversizedMedia()
        #expect(throws: (any Error).self) { try f.db.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, media: malformed, action: action) }
        let result = try f.db.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, media: [audio.prepared], action: action)
        let operations = try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_card_link_operations", values: [])
        #expect(try f.db.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, media: [audio.prepared], action: action) == result)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_card_link_operations", values: []) == operations)
        let foreign = UUID().uuidString.lowercased(); try f.addWorkspace(foreign)
        #expect(try LingroveNotebookReviewMediaStore(core: f.db.core).media(reference: audio.prepared.reference, workspaceID: foreign) == nil)
    }

    @Test func associatingRichRecipeRequiresOwnedMediaAndKeepsExistingFacesManual() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let entry = saved.document.entries[0], audio = Self.audio(text: entry.expression)
        let plan = ReviewMaterialPlan(layout: .init(front: [.init(source: .expressionAudio)], back: [.init(source: .meaning)]), audio: [.expression: audio.receipt])
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: .init(entryID: entry.id, senseID: entry.senses[0].id), materialPlan: plan)
        let card = try f.db.saveCard(workspaceId: f.workspace, input: .init(frontText: "existing prompt", backText: "existing answer", tags: []), cardId: nil, mediaAssetIdsReadyForUpload: [])
        #expect(throws: (any Error).self) { try f.db.linkLingroveNotebookCard(draft, cardId: card.cardId) }
        #expect(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).isEmpty)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_review_media", values: []) == 0)
        let link = try f.db.linkLingroveNotebookCard(draft, cardId: card.cardId, media: [audio.prepared])
        #expect(link.materialPlan == plan && link.generatedContent == nil)
        var document = saved.document, entries = document.entries; entries[0].senses[0].note = "changed"; document.entries = entries
        _ = try f.db.saveLingroveNotebook(document, basedOn: saved)
        let preserved = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId)
        #expect(preserved.frontText == card.frontText && preserved.backText == card.backText)
        #expect(try LingroveNotebookReviewMediaStore(core: f.db.core).media(reference: audio.prepared.reference, workspaceID: f.workspace) == audio.prepared)
    }

    @Test func richWireRequiresVersionAndExactMediaACKAndPreservesRecipeOnAnotherDatabase() throws {
        let source = try NotebookMediaDatabaseFixture(); defer { source.cleanUp() }
        let saved = try source.db.saveLingroveNotebook(Self.document(), basedOn: source.db.loadLingroveNotebook(workspaceId: source.workspace))
        let entry = saved.document.entries[0], sense = entry.senses[0]
        let audio = Self.audio(text: entry.expression)
        let plan = ReviewMaterialPlan(layout: .init(front: [.init(source: .expressionAudio)], back: [.init(source: .meaning), .init(source: .notes)]), audio: [.expression: audio.receipt])
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: .init(entryID: entry.id, senseID: sense.id), materialPlan: plan)
        _ = try source.db.enrollLingroveNotebookSenses([draft], scope: saved, media: [audio.prepared])
        let binding = try source.binding(), sync = LingroveNotebookReviewSyncStore(core: source.db.core)
        let stage = try sync.request(binding)
        #expect(stage.protocolVersion == 3 && stage.media == [audio.prepared] && stage.links.isEmpty)
        #expect(throws: (any Error).self) { try sync.apply(.init(protocolVersion: 1, notebookId: source.book, replicaId: source.replica,
            acknowledged: [], confirmed: [], afterSequence: 0, hasMore: false, changes: [], noteState: stage.noteState, acknowledgedNoteState: stage.noteStateDigest), request: stage, binding: binding) }
        #expect(throws: (any Error).self) { try sync.apply(.init(protocolVersion: 3, notebookId: source.book, replicaId: source.replica,
            acknowledged: [], confirmed: [], afterSequence: 0, hasMore: false, changes: [], noteState: stage.noteState, acknowledgedNoteState: stage.noteStateDigest), request: stage, binding: binding) }
        #expect(throws: (any Error).self) { try sync.apply(.init(protocolVersion: 3, notebookId: source.book, replicaId: source.replica,
            acknowledged: [], confirmed: [], afterSequence: 0, hasMore: false, changes: [], media: Self.oversizedMedia(), acknowledgedMedia: [audio.prepared.reference.digest], noteState: stage.noteState, acknowledgedNoteState: stage.noteStateDigest), request: stage, binding: binding) }
        #expect(try sync.request(binding).media == stage.media)
        try sync.apply(.init(protocolVersion: 3, notebookId: source.book, replicaId: source.replica,
            acknowledged: [], confirmed: [], afterSequence: 0, hasMore: false, changes: [], acknowledgedMedia: [audio.prepared.reference.digest], noteState: stage.noteState, acknowledgedNoteState: stage.noteStateDigest), request: stage, binding: binding)
        let publication = try sync.request(binding)
        #expect(publication.protocolVersion == 3 && publication.links.first?.value.materialPlan == plan)
        #expect(try JSONDecoder().decode(LingroveNotebookReviewRequest.self, from: JSONEncoder().encode(publication)).links.first?.value.materialPlan == plan)
        let target = try NotebookMediaDatabaseFixture(workspace: source.workspace, owner: source.owner); defer { target.cleanUp() }
        let targetSaved = try target.db.saveLingroveNotebook(saved.document, basedOn: target.db.loadLingroveNotebook(workspaceId: target.workspace))
        let targetBinding = try target.db.captureLingroveNotebookWindowBinding(scope: .init(ownerUserID: source.owner,
            workspaceID: UUID(uuidString: source.workspace)!, notebookID: source.book, replicaID: target.replica))
        let targetSync = LingroveNotebookReviewSyncStore(core: target.db.core), targetRequest = try targetSync.request(targetBinding)
        let enrollment = try #require(publication.enrollments.first?.value), link = try #require(publication.links.first?.value)
        let card = try source.db.loadActiveCard(workspaceId: source.workspace, cardId: link.cardId)
        let exercise = Exercise(enrollmentId: enrollment.id, link: link, card: card)
        let changes: [LingroveNotebookReviewResponse.Change] = [
            .init(sequence: "1", kind: "enrollment", value: try Self.json(enrollment)),
            .init(sequence: "2", kind: "exercise", value: try Self.json(exercise))]
        try targetSync.apply(.init(protocolVersion: 3, notebookId: source.book, replicaId: target.replica,
            acknowledged: [], confirmed: [], afterSequence: 2, hasMore: false, changes: changes, media: [audio.prepared], noteState: targetRequest.noteState, acknowledgedNoteState: targetRequest.noteStateDigest), request: targetRequest, binding: targetBinding)
        try target.reopen()
        #expect(try target.db.loadLingroveNotebookCardLinks(workspaceId: target.workspace).first?.materialPlan == plan)
        #expect(try target.db.loadActiveCard(workspaceId: target.workspace, cardId: card.cardId).frontText == card.frontText)
        #expect(try LingroveNotebookReviewMediaStore(core: target.db.core).media(reference: audio.prepared.reference, workspaceID: target.workspace) == audio.prepared)
        #expect(try target.db.loadLingroveNotebook(workspaceId: target.workspace).document == targetSaved.document)
    }

    @Test func batchChecksEachFrozenGroupAndCancellationLeavesNoMedia() async throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        var document = Self.document()
        var second = Self.document().entries[0]
        second.expression = "walk"; second.dictionaryForm = "walk"
        second.senses[0].examples[0].text = "walk this path"
        document.entries += [second]
        let saved = try f.db.saveLingroveNotebook(document, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let content = try f.db.loadBuiltInNotebookReview(scope: saved, now: Date())
        let selections = saved.document.entries.map { VocabularySelection(entryID: $0.id, senseID: $0.senses[0].id) }
        let drafts = try selections.map { try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: $0) }
        let actions = selections.map { NotebookBuiltInReviewAction(content: content, selection: $0) }
        let inputs = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0.generatedContent) })
        let concurrent = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selections[1])
        _ = try f.db.enrollBuiltInNotebookSense(concurrent, input: concurrent.generatedContent, action: actions[1])
        #expect(throws: (any Error).self) { try f.db.enrollBuiltInNotebookSenses(drafts, inputs: inputs, actions: actions) }
        #expect(try f.db.loadLingroveNotebookReviewEnrollments(workspaceId: f.workspace).count == 1)
        #expect(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).count == 1)
        let audio = Self.audio(text: saved.document.entries[0].expression)
        let plan = ReviewMaterialPlan(layout: .init(front: [.init(source: .expressionAudio)], back: [.init(source: .meaning)]), audio: [.expression: audio.receipt])
        let rich = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selections[0], materialPlan: plan)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try f.db.enrollBuiltInNotebookSense(rich, input: rich.generatedContent, media: [audio.prepared], action: actions[0])
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled enrollment unexpectedly committed") }
        catch { #expect(error is CancellationError) }
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_review_media", values: []) == 0)
        #expect(try f.db.loadLingroveNotebookReviewEnrollments(workspaceId: f.workspace).count == 1)
    }

    @Test func explicitAccountCopyRetainsHiddenRecipeMediaAndRewritesGeneratedBaseline() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let entry = saved.document.entries[0], sense = entry.senses[0]
        let audio = Self.audio(text: entry.expression)
        let plan = ReviewMaterialPlan(layout: .init(front: [.init(source: .expressionAudio)], back: [.init(source: .meaning)]), audio: [.expression: audio.receipt])
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: .init(entryID: entry.id, senseID: sense.id), materialPlan: plan)
        _ = try f.db.enrollLingroveNotebookSenses([draft], scope: saved, media: [audio.prepared])
        let link = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first)
        var card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: link.cardId)
        card = try f.db.saveCard(workspaceId: f.workspace, input: .init(frontText: "authored without audio", backText: card.backText, tags: card.tags), cardId: card.cardId, mediaAssetIdsReadyForUpload: [])
        card = try f.db.submitReview(workspaceId: f.workspace, reviewSubmission: .init(cardId: card.cardId, rating: .good, reviewedAtClient: "2026-11-03T07:00:00.000Z", reviewedTimeZone: "UTC"))
        let target = UUID().uuidString.lowercased(); try f.addWorkspace(target)
        let targetBook = try f.db.loadLingroveNotebook(workspaceId: target).notebookId
        try f.db.core.inTransaction {
            try WorkspaceForker(core: f.db.core, workspaceSettingsStore: f.db.workspaceSettingsStore,
                shellStore: WorkspaceShellStore(core: f.db.core, workspaceSettingsStore: f.db.workspaceSettingsStore), mediaTransferStore: f.db.mediaTransferStore,
                outboxRewriter: WorkspaceOutboxRewriter(core: f.db.core)).copyForNotebookOwnership(
                    sourceWorkspaceID: f.workspace, targetWorkspaceID: target, notebookID: targetBook, managedOnly: true)
        }
        let copiedLink = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: target).first)
        let copiedCard = try #require(try f.db.cardStore.loadOptionalCardIncludingDeleted(workspaceId: target, cardId: copiedLink.cardId))
        #expect(copiedLink.materialPlan == plan && copiedCard.frontText == card.frontText)
        #expect(copiedCard.reps == card.reps && copiedCard.dueAt == card.dueAt)
        #expect(try f.db.cardStore.loadReviewEvents(workspaceId: target).count == 1)
        #expect(try LingroveNotebookReviewMediaStore(core: f.db.core).media(reference: audio.prepared.reference, workspaceID: target) == audio.prepared)
        let id = LingroveNotebookCardMaterial.mediaAssetID(reference: audio.prepared.reference, workspaceID: target)
        #expect(copiedLink.generatedContent?.frontText.contains(id) == true)
        #expect(copiedLink.generatedContent?.frontText != link.generatedContent?.frontText)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM media_transfer_queue WHERE workspace_id=?", values: [.text(target)]) == 0)
    }

    @Test func schema38UpgradePreservesCurrentCorpusManualEditsAndRatings() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let entry = saved.document.entries[0]
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: .init(entryID: entry.id, senseID: entry.senses[0].id))
        _ = try f.db.enrollLingroveNotebookSense(draft)
        let link = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first)
        var card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: link.cardId)
        card = try f.db.saveCard(workspaceId: f.workspace, input: .init(frontText: "manual", backText: card.backText, tags: ["personal"]), cardId: card.cardId, mediaAssetIdsReadyForUpload: [])
        card = try f.db.submitReview(workspaceId: f.workspace, reviewSubmission: .init(cardId: card.cardId, rating: .good, reviewedAtClient: "2026-11-03T05:00:00.000Z", reviewedTimeZone: "UTC"))
        let events = try f.db.cardStore.loadReviewEvents(workspaceId: f.workspace)
        try f.db.core.executeScript(sql: "DROP TABLE notebook_review_media; ALTER TABLE notebook_card_links DROP COLUMN material_plan_json; PRAGMA user_version=38;", errorContext: "Synthetic current schema38")
        try f.reopen()
        #expect(try f.db.core.scalarInt(sql: "PRAGMA user_version", values: []) == LocalDatabaseSchema.currentVersion)
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId) == card)
        #expect(try f.db.cardStore.loadReviewEvents(workspaceId: f.workspace) == events)
        #expect(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first?.materialPlan == nil)
    }

    private struct Exercise: Encodable { let enrollmentId: UUID; let link: LingroveNotebookCardLink; let card: Card }
    private static func json<T: Encodable>(_ value: T) throws -> VocabularyWireJSON { try JSONDecoder().decode(VocabularyWireJSON.self, from: JSONEncoder().encode(value)) }
    private static func oversizedMedia() -> [ReviewMaterialPreparedMedia] {
        ["b", "c"].map { .init(reference: .init(digest: String(repeating: $0, count: 64), mimeType: "audio/wav", byteCount: Int.max), data: Data()) }
    }
    private static func audio(text: String) -> (prepared: ReviewMaterialPreparedMedia, receipt: ReviewMaterialAudio) {
        var bytes = Data("RIFF".utf8); bytes.append(contentsOf: [36, 0, 0, 0]); bytes.append(Data("WAVEfmt ".utf8))
        bytes.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0]); bytes.append(Data("data".utf8)); bytes.append(contentsOf: [0, 0, 0, 0])
        let reference = ReviewMaterialMediaReference(digest: ReviewMaterialMediaReference.digest(bytes), mimeType: "audio/wav", byteCount: bytes.count)
        return (.init(reference: reference, data: bytes), .init(reference: reference, textHash: ReviewMaterialAudio.textHash(text), fingerprint: String(repeating: "a", count: 64)))
    }
    private static func document() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 100)
        let example = VocabularyExample(id: UUID(), text: "take this path", translation: "a translation", ranges: [.init(NSRange(location: 0, length: 4))], completeness: .sentence, meaning: "a contextual meaning", createdAt: now)
        let sense = VocabularySense(id: UUID(), meaning: "a meaning", meaningLanguage: .english, meaningOrigin: .user, note: "a note", examples: [example], isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        return VocabularyDocument(entries: [.init(id: UUID(), expression: "take", dictionaryForm: "take", language: .english, kind: .word, senses: [sense], createdAt: now, updatedAt: now)])
    }
}
