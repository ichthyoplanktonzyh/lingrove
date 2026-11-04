import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The sheet owns an editable definition and its original CAS value. Copy creates new type
/// and card-template identities; Save updates the original type without changing card IDs.
struct ReviewNoteTypeEditorDraft: Identifiable {
    let id = UUID()
    var type: ReviewNoteType
    var expected: ReviewNoteType?
    let scope: LingroveNotebookSnapshot
    var makeDefault = false
    init(type: ReviewNoteType, scope: LingroveNotebookSnapshot) {
        self.type = type; expected = type; self.scope = scope
    }
    mutating func duplicate() {
        type.id = UUID(); type.revision = 1
        type.templates = type.templates.map { var value = $0; value.id = UUID(); return value }
        expected = nil
    }
}
