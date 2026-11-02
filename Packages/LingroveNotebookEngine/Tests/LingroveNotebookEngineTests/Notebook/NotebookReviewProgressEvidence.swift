import Foundation
@testable import LingroveNotebookEngine

/// Source refresh may author faces and provenance without changing the scheduler truth.
/// Keep all other Card fields byte-comparable, including FSRS state and immutable creation.
func notebookReviewProgressEvidence(_ card: Card) throws -> Data {
    let data = try JSONEncoder().encode(card)
    guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
    for key in ["frontText", "backText", "tags", "clientUpdatedAt", "lastOperationId", "updatedAt"] {
        fields.removeValue(forKey: key)
    }
    return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
}
