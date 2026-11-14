import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The session owns this frozen confirmation until Add or Cancel. Source selections and the
/// shared Note type are the complete intent; the engine creates all template Cards atomically.
nonisolated struct BuiltInReviewBatchDraft: Identifiable, Sendable {
    let id = UUID()
    let content: NotebookBuiltInReviewSnapshot
    let selections: [VocabularySelection]

    init(content: NotebookBuiltInReviewSnapshot, selections: [VocabularySelection]) throws {
        guard !selections.isEmpty, Set(selections).count == selections.count else {
            throw VocabularyError.editConflict
        }
        self.content = content
        self.selections = selections
    }
}
