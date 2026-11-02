import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// One preparation sheet owns one unsaved intent and its original database lifetime. The
/// session can discard this value on Cancel or a repository change without writing anything.
/// Generated material stays separate from authored fields so example changes use three-way
/// ownership, just like later source refreshes in the shared engine.
nonisolated struct BuiltInReviewDraft: Identifiable, Sendable {
    enum Purpose: Sendable {
        case enrollment
        case additionalExercise
        case editing(Card, LingroveNotebookCardLink)
    }

    let id: UUID
    let snapshot: LingroveNotebookSnapshot
    let selection: VocabularySelection
    let purpose: Purpose
    let action: NotebookBuiltInReviewAction
    let expectedEnrollments: [LingroveNotebookReviewEnrollment]
    var exampleID: UUID?
    var front: String
    var back: String
    var tags: [String]
    var generated: CardEditorInput?

    var input: CardEditorInput { .init(frontText: front, backText: back, tags: tags) }
    var canSave: Bool { !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(content: NotebookBuiltInReviewSnapshot, selection: VocabularySelection, additional: Bool = false) throws {
        let projected = try LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: selection)
        id = projected.id
        snapshot = content.scope
        self.selection = selection
        purpose = additional ? .additionalExercise : .enrollment
        action = .init(content: content, selection: selection)
        expectedEnrollments = content.review.groups[selection.senseID]?.enrollments ?? []
        exampleID = nil
        generated = projected.generatedContent
        front = projected.generatedContent.frontText
        back = projected.generatedContent.backText
        tags = projected.generatedContent.tags
    }

    init(content: NotebookBuiltInReviewSnapshot, card: Card, link: LingroveNotebookCardLink,
         selection: VocabularySelection) {
        id = UUID()
        snapshot = content.scope
        self.selection = selection
        purpose = .editing(card, link)
        action = .init(content: content, selection: selection)
        expectedEnrollments = content.review.groups[selection.senseID]?.enrollments ?? []
        exampleID = link.source.exampleId
        generated = link.generatedContent
        front = card.frontText
        back = card.backText
        tags = card.tags
    }

    mutating func chooseExample(_ id: UUID?) {
        let source: LingroveNotebookCardSource
        if case let .editing(_, link) = purpose {
            source = .init(workspaceId: snapshot.workspaceId, notebookId: snapshot.notebookId,
                entryId: link.source.entryId, senseId: link.source.senseId, exampleId: id)
        } else {
            source = .init(workspaceId: snapshot.workspaceId, notebookId: snapshot.notebookId,
                entryId: selection.entryID, senseId: selection.senseID, exampleId: id)
        }
        guard let material = LingroveNotebookCardMaterial.resolve(source: source, snapshot: snapshot) else { return }
        let refreshed = LingroveNotebookCardMaterial.refreshed(current: input, previous: generated, latest: material.content)
        exampleID = id
        front = refreshed.frontText
        back = refreshed.backText
        tags = refreshed.tags
        generated = material.content
    }

    func creationDraft() throws -> LingroveNotebookCardDraft {
        try LingroveNotebookCardMaterial.draft(snapshot: snapshot, selection: selection, exampleId: exampleID, intentId: id)
    }
}
