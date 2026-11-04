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

    @discardableResult
    public func enrollLingroveNotebookSense(_ draft: LingroveNotebookCardDraft) throws -> [LingroveNotebookReviewEnrollment] {
        try self.enrollLingroveNotebookSenses([draft])
    }

    /// All selected senses commit together. A failure in a later projection rolls back earlier
    /// enrollments as well, so a multi-select action never silently enrolls only part of a list.
    public func enrollLingroveNotebookSenses(_ drafts: [LingroveNotebookCardDraft], scope: LingroveNotebookSnapshot? = nil,
        preparedInputs: [UUID: CardEditorInput] = [:], media: [ReviewMaterialPreparedMedia] = [],
        actions: [NotebookBuiltInReviewAction] = [], action: NotebookBuiltInReviewAction? = nil) throws -> [LingroveNotebookReviewEnrollment] {
        try Task.checkCancellation()
        guard let first = drafts.first, Set(drafts.map(\.id)).count == drafts.count,
              Set(drafts.map { $0.source.senseId }).count == drafts.count,
              drafts.allSatisfy({ $0.source.workspaceId == first.source.workspaceId &&
                  $0.source.notebookId == first.source.notebookId && $0.sourceRevision == first.sourceRevision }) else {
            throw VocabularyError.editConflict
        }
        return try self.core.inTransaction {
            try self.lingroveNotebookCardLinkStore.requireActiveScope(first.source)
            let snapshot = try self.lingroveNotebookStore.readSnapshot(workspaceId: first.source.workspaceId)
            if let scope { try requireCurrentScopeInTransaction(scope, requireRevision: true) }
            if let action { try requireCurrentScopeInTransaction(action.scope, requireRevision: true) }
            var result: [LingroveNotebookReviewEnrollment] = []
            var seen = Set<UUID>()
            for draft in drafts {
                for value in try self.persistNotebookEnrollment(draft, snapshot: snapshot,
                    input: preparedInputs[draft.id], media: media, action: actions.first(where: { $0.selection.senseID == draft.source.senseId }) ?? action) where seen.insert(value.id).inserted {
                    result.append(value)
                }
            }
            return result
        }
    }

    private func persistNotebookEnrollment(
        _ draft: LingroveNotebookCardDraft, snapshot: LingroveNotebookSnapshot, input: CardEditorInput?,
        media: [ReviewMaterialPreparedMedia], action: NotebookBuiltInReviewAction?
    ) throws -> [LingroveNotebookReviewEnrollment] {
        try Task.checkCancellation()
        let fingerprint = try input.map {
            try LingroveNotebookCardMaterial.fingerprint(NotebookPreparedEnrollment(draft: draft, input: $0))
        } ?? LingroveNotebookCardMaterial.fingerprint(draft)
        if let replay = try self.lingroveNotebookReviewStore.replay(workspaceId: draft.source.workspaceId,
            requestId: draft.id, fingerprint: fingerprint) { return replay }
        // Scope/generation was checked before replay. An exact committed intent is a read of
        // its current result, while a new intent must still match every displayed review row.
        if let action { try requireBuiltInReviewActionInTransaction(action) }
        try self.lingroveNotebookCardLinkStore.validate(draft, against: snapshot)
        if let input { try cardStore.validateCardInput(input: input) }
        var enrollments = try self.lingroveNotebookReviewStore.matching(source: draft.source, snapshot: snapshot)
        let now = nowIsoTimestamp()
        if enrollments.isEmpty {
            enrollments = [try self.lingroveNotebookReviewStore.insert(source: draft.source, now: now)]
        } else {
            // Merged sources retain distinct histories, while one explicit selection resumes
            // their complete resolved group instead of manufacturing another exercise.
            enrollments = try enrollments.map { try self.lingroveNotebookReviewStore.update($0, status: .active) }
        }
        if try !self.lingroveNotebookReviewStore.hasLiveExercise(enrollments) {
            if !enrollments.contains(where: { $0.senseId == draft.source.senseId }) {
                enrollments.append(try lingroveNotebookReviewStore.insert(source: draft.source, now: now))
            }
            guard let ownerIndex = enrollments.firstIndex(where: { $0.senseId == draft.source.senseId }) else { throw VocabularyError.editConflict }
            let history = try enrollments.flatMap { try lingroveNotebookReviewStore.exercises($0).map(\.cardId) }.sorted().joined(separator: ",")
            let suffix = history.isEmpty ? "" : "|after|" + history
            let linkID = LingroveNotebookCardMaterial.stableID("link" + suffix, workspace: draft.source.workspaceId, sense: draft.source.senseId)
            let cardID = LingroveNotebookCardMaterial.stableID("card" + suffix, workspace: draft.source.workspaceId, sense: draft.source.senseId).uuidString.lowercased()
            let exerciseDraft = LingroveNotebookCardDraft(id: linkID, source: draft.source,
                sourceRevision: draft.sourceRevision, generatedContent: draft.generatedContent, materialPlan: draft.materialPlan)
            let card = try self.persistNewLingroveNotebookCard(draft: exerciseDraft,
                input: input ?? exerciseDraft.generatedContent, mediaAssetIdsReadyForUpload: [], validatedSnapshot: snapshot, newCardID: cardID, media: media)
            enrollments[ownerIndex] = try self.lingroveNotebookReviewStore.attach(cardId: card.cardId, linkId: exerciseDraft.id,
                to: enrollments[ownerIndex], now: now)
        }
        try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(snapshot)
        try self.lingroveNotebookReviewStore.recordRequest(workspaceId: draft.source.workspaceId,
            requestId: draft.id, fingerprint: fingerprint, result: enrollments)
        return enrollments
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
            let snapshot = try self.lingroveNotebookStore.readSnapshot(workspaceId: first.workspaceId)
            if LingroveNotebookCardMaterial.resolvedSelection(source: first.source, snapshot: snapshot) != nil {
                let group = try self.lingroveNotebookReviewStore.matching(source: first.source, snapshot: snapshot)
                guard Set(group.map(\.id)) == Set(expected.map(\.id)) else { throw VocabularyError.editConflict }
            } else {
                // A retired source may still be paused or withdrawn. Never infer a different
                // sense from a moved example; require exact stored enrollment identities.
                if status == .active {
                    for enrollment in expected {
                        for exercise in try lingroveNotebookReviewStore.exercises(enrollment) {
                            guard let link = try lingroveNotebookCardLinkStore.find(workspaceId: enrollment.workspaceId, id: exercise.linkId), link.allowsUnavailableMaterial else { throw VocabularyError.editConflict }
                        }
                    }
                }
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

/// Authored initial faces are part of the explicit enrollment intent, while the draft retains
/// the generated source baseline for future three-way refresh. A retry cannot silently change it.
private struct NotebookPreparedEnrollment: Encodable {
    let draft: LingroveNotebookCardDraft
    let input: CardEditorInput
}

extension LingroveNotebookEngine {
    public func loadLingroveNotebookReviewSnapshot(scope: LingroveNotebookSnapshot) throws -> LingroveNotebookReviewSnapshot {
        try self.core.inReadTransaction {
            try self.lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: scope.workspaceId, notebookId: scope.notebookId)
            let current = try self.lingroveNotebookStore.readSnapshot(workspaceId: scope.workspaceId)
            guard current.revision == scope.revision, current.notebookId == scope.notebookId, current.generation == scope.generation else { throw VocabularyError.editConflict }
            let enrollments = try self.lingroveNotebookReviewStore.load(workspaceId: scope.workspaceId)
            var currentSelections: [UUID: VocabularySelection] = [:]
            for entry in current.document.entries {
                for sense in entry.senses {
                    let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
                    for id in [sense.id] + sense.mergedFrom { currentSelections[id] = selection }
                }
            }
            var grouped: [UUID: [LingroveNotebookReviewEnrollment]] = [:]
            var groupedCards: [UUID: [Card]] = [:]
            for enrollment in enrollments where enrollment.notebookId == current.notebookId {
                let selection = currentSelections[enrollment.senseId] ?? VocabularySelection(entryID: enrollment.entryId, senseID: enrollment.senseId)
                currentSelections[enrollment.senseId] = selection
                grouped[selection.senseID, default: []].append(enrollment)
                for exercise in try self.lingroveNotebookReviewStore.exercises(enrollment) {
                    if let card = try self.cardStore.loadOptionalCardIncludingDeleted(workspaceId: scope.workspaceId, cardId: exercise.cardId),
                       card.deletedAt == nil {
                        groupedCards[selection.senseID, default: []].append(card)
                    }
                }
            }
            var groups: [UUID: LingroveNotebookReviewGroup] = [:]
            for (senseId, values) in grouped {
                guard let selection = currentSelections[senseId] else { throw VocabularyError.invalidArchive }
                let cards = groupedCards[senseId] ?? []
                let unavailable = try cards.contains { card in
                    try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_material_state WHERE workspace_id=? AND card_id=? AND status NOT IN ('ready','retained')", values: [.text(scope.workspaceId), .text(card.cardId)]) > 0
                }
                let undoable = try cards.filter { card in
                    try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_last_rating rating JOIN notebook_review_schedule_heads head USING(workspace_id,card_id) WHERE rating.workspace_id=? AND rating.card_id=? AND rating.operation_id=head.operation_id AND ? IS NOT NULL", values: [.text(scope.workspaceId), .text(card.cardId), card.fsrsLastReviewedAt.map(SQLiteValue.text) ?? .null]) > 0
                }.map(\.cardId)
                groups[senseId] = .init(selection: selection, enrollments: values, cards: cards, hasUnavailableMaterial: unavailable, undoableCardIDs: Set(undoable))
            }
            return .init(workspaceId: current.workspaceId, notebookId: current.notebookId, notebookRevision: current.revision,
                groups: groups, links: try self.lingroveNotebookCardLinkStore.load(workspaceId: current.workspaceId), hasPendingSync:
                    try core.scalarInt(sql: "SELECT (SELECT count(*) FROM notebook_review_operations WHERE workspace_id=?)+(SELECT count(*) FROM notebook_card_link_operations WHERE workspace_id=?)+(SELECT count(*) FROM notebook_held_card_operations WHERE workspace_id=?)+(SELECT count(*) FROM notebook_review_undo WHERE workspace_id=? AND pending=1)+(SELECT count(*) FROM notebook_review_history_adoptions WHERE workspace_id=? AND pending=1)", values: Array(repeating: .text(current.workspaceId), count: 5)) > 0 || ReviewNoteStore(core: core).hasPendingSync(scope: current),
                    noteCards: try ReviewNoteStore(core: core).cardModels(scope: current))
        }
    }
}
