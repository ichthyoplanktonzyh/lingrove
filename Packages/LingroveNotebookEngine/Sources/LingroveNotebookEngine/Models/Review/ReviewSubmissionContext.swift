import Foundation
public struct ReviewSubmissionContext: Hashable, Sendable {
    public let selectedReviewFilter: ReviewFilter
    public let reviewQueryDefinition: ReviewQueryDefinition

    public init(selectedReviewFilter: ReviewFilter, reviewQueryDefinition: ReviewQueryDefinition) {
        self.selectedReviewFilter = selectedReviewFilter
        self.reviewQueryDefinition = reviewQueryDefinition
    }
}
