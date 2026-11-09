import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Storage integration exercises the actual source projection, native Card writer, queue
/// admission and scheduler/event persistence in one database, including restart boundaries.
@MainActor
struct LingroveNotebookReviewCompletionTests {
    @Test("Source changes follow generated fields, retain authored faces and ratings, and quarantine moved evidence")
    func sourcePreparationAndRecovery() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let selection = VocabularySelection(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        let enrollment = try #require(try f.db.enrollLingroveNotebookSense(draft).first)
        let exercise = try #require(try f.db.lingroveNotebookReviewStore.exercises(enrollment).first)
        var link = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first)
        var card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: exercise.cardId)
        let example = try #require(saved.document.entries[0].senses[0].examples.first)
        try f.db.prepareNotebookExercise(link: link, card: card, snapshot: saved, exampleID: example.id,
            input: .init(frontText: "my prompt", backText: example.translation + "\n\n" + saved.document.entries[0].expression, tags: []))
        _ = try f.db.submitReview(workspaceId: f.workspace, reviewSubmission: .init(cardId: card.cardId, rating: .good,
            reviewedAtClient: "2026-11-02T03:00:00.000Z", reviewedTimeZone: "Asia/Shanghai"))
        let reviewed = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId)
        let old = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        var updated = old.document
        updated.entries[0].senses[0].meaning = "updated meaning"
        updated.entries[0].senses[0].examples[0].translation = "updated example translation"
        let changed = try f.db.saveLingroveNotebook(updated, basedOn: old, restoringBackup: true)
        card = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId)
        #expect(card.frontText == "my prompt")
        #expect(card.backText == reviewed.backText) // This answer was explicitly authored.
        #expect(card.reps == reviewed.reps && card.dueAt == reviewed.dueAt)
        #expect(try f.db.loadReviewEventCount() == 1)
        link = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first)
        var moved = changed.document
        let evidence = moved.entries[0].senses[0].examples.removeFirst()
        moved.entries[0].senses[1].examples.append(evidence)
        let missing = try f.db.saveLingroveNotebook(moved, basedOn: changed, restoringBackup: true)
        #expect(try f.db.cardStore.loadNotebookExcludedReviewCardIds(workspaceId: f.workspace).contains(card.cardId))
        #expect(try f.db.loadLingroveNotebookReviewSnapshot(scope: missing).groups[selection.senseID]?.hasUnavailableMaterial == true)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId).reps == reviewed.reps)
        let currentLink = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first)
        #expect(throws: (any Error).self) { try f.db.prepareNotebookExercise(link: link, card: card, snapshot: changed,
            exampleID: nil, input: .init(frontText: "stale", backText: "stale", tags: [])) }
        try f.db.prepareNotebookExercise(link: currentLink, card: card, snapshot: missing, exampleID: nil,
            input: .init(frontText: card.frontText, backText: card.backText, tags: card.tags))
        #expect(try !f.db.cardStore.loadNotebookExcludedReviewCardIds(workspaceId: f.workspace).contains(card.cardId))
        try f.reopen()
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId).dueAt == reviewed.dueAt)
        #expect(try f.db.loadReviewEventCount() == 1)
        // Retiring the entire source keeps a visible historical group. Explicitly using its
        // saved faces restores admission under that original identity, never another sense.
        let beforeRemoval = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        let retired = try f.db.saveLingroveNotebook(VocabularyDocument(), basedOn: beforeRemoval, restoringBackup: true)
        let retainedLink = try #require(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first)
        let retainedCard = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId)
        #expect(try f.db.loadLingroveNotebookReviewSnapshot(scope: retired).groups.count == 1)
        try f.db.retainNotebookExercise(link: retainedLink, card: retainedCard, snapshot: retired)
        #expect(try !f.db.cardStore.loadNotebookExcludedReviewCardIds(workspaceId: f.workspace).contains(card.cardId))
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId).dueAt == reviewed.dueAt)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebookCardLinks(workspaceId: f.workspace).first?.allowsUnavailableMaterial == true)
    }

    @Test("Selection, multiple exercises, withdrawal, deletion and re-entry retain sense ownership")
    func participationLifecycle() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        var saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let selection = VocabularySelection(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        let enrolled = try f.db.enrollLingroveNotebookSense(draft)
        #expect(try f.db.enrollLingroveNotebookSense(draft) == enrolled)
        let extra = try f.db.addNotebookExercise(try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection))
        var group = try #require(try f.db.loadLingroveNotebookReviewSnapshot(scope: saved).groups[selection.senseID])
        #expect(group.cards.count == 2)
        #expect(try f.db.loadLingroveNotebookReviewSnapshot(scope: saved).groups.count == 1)
        _ = try f.db.setLingroveNotebookReviewStatus(.paused, enrollments: group.enrollments)
        #expect(try f.db.cardStore.loadNotebookExcludedReviewCardIds(workspaceId: f.workspace).contains(extra.cardId))
        #expect(throws: (any Error).self) { _ = try f.db.submitReview(workspaceId: f.workspace,
            reviewSubmission: .init(cardId: extra.cardId, rating: .good, reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC")) }
        group = try #require(try f.db.loadLingroveNotebookReviewSnapshot(scope: saved).groups[selection.senseID])
        _ = try f.db.setLingroveNotebookReviewStatus(.withdrawn, enrollments: group.enrollments)
        var uncollected = saved.document
        for entry in uncollected.catalog.indices {
            for sense in uncollected.catalog[entry].senses.indices {
                uncollected.catalog[entry].senses[sense].isSavedWithoutContext = false
            }
        }
        saved = try f.db.saveLingroveNotebook(uncollected, basedOn: saved, restoringBackup: true)
        _ = try f.db.enrollLingroveNotebookSense(try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection))
        group = try #require(try f.db.loadLingroveNotebookReviewSnapshot(scope: saved).groups[selection.senseID])
        #expect(group.status == .active && group.cards.count == 2)
        for card in group.cards { _ = try f.db.deleteCard(workspaceId: f.workspace, cardId: card.cardId) }
        _ = try f.db.enrollLingroveNotebookSense(try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection))
        let rebuilt = try #require(try f.db.loadLingroveNotebookReviewSnapshot(scope: saved).groups[selection.senseID])
        #expect(rebuilt.cards.count == 1)
        #expect(!group.cards.map(\.cardId).contains(rebuilt.cards[0].cardId))
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace).document == saved.document)
    }

    @Test("A merge retains historical exercise owners and gives new exercises a matching stable owner")
    func mergedExerciseOwnership() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        var entry = saved.document.entries[0]
        let original = entry.senses[0]
        _ = try f.db.enrollLingroveNotebookSense(LingroveNotebookCardMaterial.draft(snapshot: saved, selection: .init(entryID: entry.id, senseID: original.id)))
        var surviving = entry.senses[1]
        let paused = try f.db.enrollLingroveNotebookSense(LingroveNotebookCardMaterial.draft(snapshot: saved,
            selection: .init(entryID: entry.id, senseID: surviving.id)))
        _ = try f.db.setLingroveNotebookReviewStatus(.paused, enrollments: paused)
        surviving.mergedFrom = [original.id]; surviving.examples = original.examples
        entry.senses = [surviving]
        var document = saved.document; document.entries = [entry]
        let merged = try f.db.saveLingroveNotebook(document, basedOn: saved, restoringBackup: true)
        let selection = VocabularySelection(entryID: entry.id, senseID: surviving.id)
        let added = try f.db.addNotebookExercise(LingroveNotebookCardMaterial.draft(snapshot: merged, selection: selection))
        #expect(try !f.db.cardStore.loadNotebookExcludedReviewCardIds(workspaceId: f.workspace).contains(added.cardId))
        let group = try #require(try f.db.loadLingroveNotebookReviewSnapshot(scope: merged).groups[surviving.id])
        #expect(group.cards.count == 3 && group.enrollments.count == 2)
        for owner in group.enrollments {
            for exercise in try f.db.lingroveNotebookReviewStore.exercises(owner) {
                #expect(try f.db.lingroveNotebookCardLinkStore.find(workspaceId: f.workspace, id: exercise.linkId)?.source.senseId == owner.senseId)
            }
        }
    }

    @Test("A bounded offline batch retains an undo whose event and schedule are beyond the sent prefix")
    func offlineBatchUndoDependency() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let selection = VocabularySelection(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id)
        let owner = try #require(try f.db.enrollLingroveNotebookSense(LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)).first)
        let card = try #require(try f.db.lingroveNotebookReviewStore.exercises(owner).first).cardId
        let start = Date()
        for index in 0..<201 {
            _ = try f.db.submitReview(workspaceId: f.workspace, reviewSubmission: .init(cardId: card, rating: .again,
                reviewedAtClient: formatIsoTimestamp(date: start.addingTimeInterval(Double(index))), reviewedTimeZone: "UTC"))
        }
        try f.db.undoLastNotebookRating(workspaceId: f.workspace, cardId: card, generation: f.db.loadLingroveNotebook(workspaceId: f.workspace).generation)
        let request = try LingroveNotebookReviewSyncStore(core: f.db.core).request(f.binding())
        // One initial Card plus 199 complete rating/event pairs. The last
        // unpaired event waits with its schedule instead of filling slot 400.
        #expect(request.operations.count == 399)
        #expect(request.undos.isEmpty)
        #expect(try f.db.loadReviewEventCount() == 201)
        #expect(try f.db.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_undo WHERE pending=1", values: []) == 1)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card).reps == 200)
    }

    static func document() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1793580000)
        let example = VocabularyExample(id: UUID(), text: "We found a quiet harbor.", translation: "a translated example", ranges: [],
            completeness: .sentence, meaning: "a sheltered place", meaningLanguage: .english, meaningOrigin: .user, createdAt: now)
        let sense = VocabularySense(id: UUID(), meaning: "a sheltered place", meaningLanguage: .english, meaningOrigin: .user,
            examples: [example], isSavedWithoutContext: false, createdAt: now, updatedAt: now)
        let other = VocabularySense(id: UUID(), meaning: "to retain a thought", meaningLanguage: .english, meaningOrigin: .user,
            isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        return .init(entries: [.init(id: UUID(), expression: "harbor", dictionaryForm: "harbor", language: .english,
            kind: .word, senses: [sense, other], createdAt: now, updatedAt: now)])
    }
}
