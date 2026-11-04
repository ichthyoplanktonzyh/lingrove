import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// A sheet edits only the note's own fields and example binding. Corpus fields remain live
/// projections; the session passes the original note to the writer for an atomic CAS save.
struct ReviewNoteEditorDraft: Identifiable, Sendable {
    let id = UUID()
    var note: ReviewNote
    let expected: ReviewNote
    let type: ReviewNoteType
    let scope: LingroveNotebookSnapshot
    init(model: NotebookReviewNoteCard, scope: LingroveNotebookSnapshot) {
        note = model.note; expected = model.note; type = model.noteType; self.scope = scope
    }
}
