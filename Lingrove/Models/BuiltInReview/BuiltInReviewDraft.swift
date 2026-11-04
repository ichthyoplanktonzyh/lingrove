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
    var materialPlan: ReviewMaterialPlan
    var importedImages: [String: Data] = [:]
    var preparedMedia: [ReviewMaterialPreparedMedia] = []
    var exampleID: UUID? {
        get { materialPlan.exampleID }
        set { materialPlan.exampleID = newValue }
    }
    var front: String
    var back: String
    var tags: [String]
    var generated: CardEditorInput?

    var input: CardEditorInput { .init(frontText: front, backText: back, tags: tags) }
    var canSave: Bool { !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(content: NotebookBuiltInReviewSnapshot, selection: VocabularySelection, additional: Bool = false) throws {
        let plan = ReviewMaterialPlan(layout: ReviewMaterialResolver.preset(0))
        let projected = try LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: selection, materialPlan: plan)
        id = projected.id
        snapshot = content.scope
        self.selection = selection
        purpose = additional ? .additionalExercise : .enrollment
        action = .init(content: content, selection: selection)
        expectedEnrollments = content.review.groups[selection.senseID]?.enrollments ?? []
        materialPlan = plan
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
        materialPlan = link.materialPlan ?? .init(layout: ReviewMaterialResolver.preset(0), exampleID: link.source.exampleId)
        generated = link.generatedContent
        front = card.frontText
        back = card.backText
        tags = card.tags
    }

    /// Three-way face ownership is reused while editing the recipe: only a face still equal
    /// to its generated baseline follows new sources. A hand-edited face remains the user's.
    mutating func chooseMaterial(_ plan: ReviewMaterialPlan) {
        var plan = plan
        plan.audio = plan.audio.filter { plan.layout.audioKinds.contains($0.key) }
        materialPlan = plan
        let images = VocabularyContentPolicy.images(plan.layout.customContent)
        let filenames = Set(images.map(\.filename))
        importedImages = importedImages.filter { filenames.contains($0.key) }
        let media = Set(images.map(ReviewMaterialMediaReference.init(image:)) + plan.audio.values.map(\.reference))
        preparedMedia = preparedMedia.filter { media.contains($0.reference) }
        guard let source = BuiltInReviewSource.value(selection, in: snapshot),
              let latest = try? LingroveNotebookCardMaterial.render(entry: source.entry, sense: source.sense,
                  plan: plan, workspaceID: snapshot.workspaceId) else { return }
        let refreshed = LingroveNotebookCardMaterial.refreshed(current: input, previous: generated, latest: latest)
        front = refreshed.frontText
        back = refreshed.backText
        tags = refreshed.tags
        generated = latest
    }

    mutating func chooseExample(_ id: UUID?) {
        var plan = materialPlan
        plan.exampleID = id
        chooseMaterial(plan)
    }

    /// Match practice rendering: only a face equal to its generated baseline uses rich parts.
    /// An authored face is previewed as its own saved text, never as the underlying recipe.
    func previewParts(answer: Bool) -> [ReviewResolvedPart]? {
        let text = answer ? back : front
        let baseline = answer ? generated?.backText : generated?.frontText
        guard text == baseline, let source = BuiltInReviewSource.value(selection, in: snapshot),
              let resolved = try? ReviewMaterialResolver.resolve(entry: source.entry, sense: source.sense,
                                                                 plan: materialPlan) else { return nil }
        return answer ? resolved.back : resolved.front
    }

    func isAuthored(answer: Bool) -> Bool {
        (answer ? back : front) != (answer ? generated?.backText : generated?.frontText)
    }

    mutating func restoreGeneratedFace(answer: Bool) {
        guard let generated else { return }
        if answer { back = generated.backText } else { front = generated.frontText }
    }

    func creationDraft() throws -> LingroveNotebookCardDraft {
        try LingroveNotebookCardMaterial.draft(snapshot: snapshot, selection: selection,
            exampleId: exampleID, intentId: id, materialPlan: materialPlan)
    }
}

/// A confirmed batch freezes each displayed sense group and retains intent IDs for retry.
/// The one shared-engine command commits the entire selection or no enrollment at all.
nonisolated struct BuiltInReviewBatchDraft: Identifiable, Sendable {
    let id = UUID()
    let content: NotebookBuiltInReviewSnapshot
    let drafts: [BuiltInReviewDraft]

    init(content: NotebookBuiltInReviewSnapshot, selections: [VocabularySelection]) throws {
        self.content = content
        drafts = try selections.map { try .init(content: content, selection: $0) }
    }
}
