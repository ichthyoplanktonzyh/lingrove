import Foundation
import LingroveNotebook
@testable import LingroveNotebookEngine

extension LingroveNotebookEngine {
    func enrollNoteSources(_ selections: [VocabularySelection], scope: LingroveNotebookSnapshot) throws
        -> [LingroveNotebookReviewEnrollment] {
        _ = try enrollReviewNotes(selections: selections, type: ReviewNoteDefaults.type, scope: scope)
        let review = try loadLingroveNotebookReviewSnapshot(scope: scope)
        return selections.flatMap { review.groups[$0.senseID]?.enrollments ?? [] }
    }

    func submitTestNoteRating(_ submission: ReviewSubmission, basedOn scope: LingroveNotebookSnapshot,
                              expectedCardOperationID: String? = nil) throws -> Card {
        let model = try ReviewNoteStore(core: core).cardModels(scope: scope)[submission.cardId]
        return try submitNotebookRating(.init(cardId: submission.cardId, rating: submission.rating,
            reviewedAtClient: submission.reviewedAtClient, reviewedTimeZone: submission.reviewedTimeZone,
            noteVersion: model?.questionVersion(in: scope)), basedOn: scope,
            expectedCardOperationID: expectedCardOperationID)
    }
}
