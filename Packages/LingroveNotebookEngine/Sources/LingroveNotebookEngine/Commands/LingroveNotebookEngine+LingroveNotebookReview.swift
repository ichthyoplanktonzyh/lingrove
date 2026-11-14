import Foundation
import LingroveNotebook

/// This is the only corpus-to-review admission operation. The facade owns one writer
/// transaction spanning enrollment, Card, provenance, sync hold and pending journals. Saving a
/// notebook document never calls it. UI passes a frozen saved-source draft and retains its ID
/// across retries; the database revalidates the active scope and source before a new commit.
extension LingroveNotebookEngine {
    public func loadLingroveNotebookReviewEnrollments(workspaceId: String) throws -> [LingroveNotebookReviewEnrollment] {
        try self.lingroveNotebookReviewStore.load(workspaceId: workspaceId)
    }

    /// Pausing/withdrawing records participation only. It never changes dueAt, reps, faces or
    /// events. The complete resolved sense group is required so a stale screen cannot leave a
    /// second exercise running after a merge, or undo a newer participation choice.
    @discardableResult
    public func setLingroveNotebookReviewStatus(
        _ status: LingroveNotebookReviewStatus, enrollments expected: [LingroveNotebookReviewEnrollment],
        requestId: UUID = UUID(), scope: LingroveNotebookSnapshot? = nil, action: NotebookBuiltInReviewAction? = nil
    ) throws -> [LingroveNotebookReviewEnrollment] {
        try Task.checkCancellation()
        guard let first = expected.first,
              Set(expected.map(\.id)).count == expected.count,
              expected.allSatisfy({ $0.workspaceId == first.workspaceId && $0.notebookId == first.notebookId }) else {
            throw VocabularyError.editConflict
        }
        let ordered = expected.sorted { $0.id.uuidString < $1.id.uuidString }
        let fingerprint = try LingroveNotebookCardMaterial.fingerprint(NotebookReviewStatusIntent(status: status, expected: ordered))
        return try self.core.inTransaction {
            try Task.checkCancellation()
            try self.lingroveNotebookCardLinkStore.requireActiveScope(first.source)
            if let scope { try requireCurrentScopeInTransaction(scope, requireRevision: false) }
            if let action { try requireCurrentScopeInTransaction(action.scope, requireRevision: true) }
            if let replay = try self.lingroveNotebookReviewStore.replay(workspaceId: first.workspaceId,
                requestId: requestId, fingerprint: fingerprint) { return replay }
            if let action { try requireBuiltInReviewActionInTransaction(action) }
            if let selection = try resolvedNotebookSelection(senseID: first.senseId, workspace: first.workspaceId),
               let saved = try notebookSense(id: selection.senseID, workspace: first.workspaceId) {
                let group = try self.lingroveNotebookReviewStore.load(workspaceId: first.workspaceId,
                    notebookId: first.notebookId, senseIDs: Set([saved.sense.id] + saved.sense.mergedFrom))
                guard Set(group.map(\.id)) == Set(expected.map(\.id)) else { throw VocabularyError.editConflict }
            } else {
                // A retired source may still be paused or withdrawn. Never infer a different
                // sense from a moved example; require exact stored enrollment identities.
                if status == .active { throw VocabularyError.editConflict }
            }
            if status == .active, try !self.lingroveNotebookReviewStore.hasLiveExercise(ordered) {
                throw VocabularyError.editConflict
            }
            try Task.checkCancellation()
            let result = try ordered.map { try self.lingroveNotebookReviewStore.update($0, status: status) }
            try self.lingroveNotebookReviewStore.recordRequest(workspaceId: first.workspaceId,
                requestId: requestId, fingerprint: fingerprint, result: result)
            return result
        }
    }
}

/// Stable serialized intent separates a replay from a new action. It includes the caller's
/// exact CAS values; later changes cannot be overwritten by retrying an older status request.
private struct NotebookReviewStatusIntent: Encodable {
    let status: LingroveNotebookReviewStatus
    let expected: [LingroveNotebookReviewEnrollment]
}

extension LingroveNotebookEngine {
    public func loadLingroveNotebookReviewSnapshot(scope: LingroveNotebookSnapshot) throws -> LingroveNotebookReviewSnapshot {
        try self.core.inReadTransaction {
            try self.lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: scope.workspaceId, notebookId: scope.notebookId)
            let current = try self.lingroveNotebookStore.readSnapshot(workspaceId: scope.workspaceId)
            guard current.revision == scope.revision, current.notebookId == scope.notebookId, current.generation == scope.generation else { throw VocabularyError.editConflict }
            return try loadLingroveNotebookReviewSnapshotInTransaction(current: current)
        }
    }

    /// The full notebook screen also reads queue and history in the same SQLite snapshot.
    func loadLingroveNotebookReviewSnapshotInTransaction(current: LingroveNotebookSnapshot) throws -> LingroveNotebookReviewSnapshot {
        let noteCards = try ReviewNoteStore(core: core).cardModels(scope: current)
        let enrollments = try self.lingroveNotebookReviewStore.load(workspaceId: current.workspaceId)
        let rows = try NotebookReviewReadRows(core: core, scope: current)
        var currentSelections: [UUID: VocabularySelection] = [:]
        for entry in current.document.catalog {
            try Task.checkCancellation()
            for sense in entry.senses {
                let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
                for id in [sense.id] + sense.mergedFrom { currentSelections[id] = selection }
            }
        }
        var grouped: [UUID: [LingroveNotebookReviewEnrollment]] = [:]
        var groupedCards: [UUID: [Card]] = [:]
        for enrollment in enrollments where enrollment.notebookId == current.notebookId {
            try Task.checkCancellation()
            let exercises = (rows.exercises[enrollment.id] ?? []).filter { noteCards[$0.cardId] != nil }
            guard !exercises.isEmpty else { continue }
            let selection = currentSelections[enrollment.senseId] ?? VocabularySelection(entryID: enrollment.entryId, senseID: enrollment.senseId)
            currentSelections[enrollment.senseId] = selection
            grouped[selection.senseID, default: []].append(enrollment)
            for exercise in exercises {
                if let card = rows.cards[exercise.cardId] {
                    groupedCards[selection.senseID, default: []].append(card)
                }
            }
        }
        var groups: [UUID: LingroveNotebookReviewGroup] = [:]
        for (senseId, values) in grouped {
            guard let selection = currentSelections[senseId] else { throw VocabularyError.invalidArchive }
            let cards = groupedCards[senseId] ?? []
            let unavailable = cards.contains { card in
                guard noteCards[card.cardId]?.noteType.templates.first(where: { $0.id == noteCards[card.cardId]?.templateID })?.enabled != false else { return false }
                return rows.unavailable.contains(card.cardId)
            }
            let undoable = cards.filter { $0.fsrsLastReviewedAt != nil && rows.undoable.contains($0.cardId) }.map(\.cardId)
            groups[senseId] = .init(selection: selection, enrollments: values, cards: cards, hasUnavailableMaterial: unavailable, undoableCardIDs: Set(undoable))
        }
        return .init(workspaceId: current.workspaceId, notebookId: current.notebookId, notebookRevision: current.revision,
            groups: groups, links: try self.lingroveNotebookCardLinkStore.load(workspaceId: current.workspaceId)
                .filter { noteCards[$0.cardId] != nil }, hasPendingSync:
                try core.scalarInt(sql: "SELECT (SELECT count(*) FROM notebook_review_operations WHERE workspace_id=?)+(SELECT count(*) FROM notebook_card_link_operations WHERE workspace_id=?)+(SELECT count(*) FROM notebook_held_card_operations WHERE workspace_id=?)+(SELECT count(*) FROM notebook_review_undo WHERE workspace_id=? AND pending=1)+(SELECT count(*) FROM notebook_review_history_adoptions WHERE workspace_id=? AND pending=1)", values: Array(repeating: .text(current.workspaceId), count: 5)) > 0 || ReviewNoteStore(core: core).hasPendingSync(scope: current),
                noteCards: noteCards)
    }
}
