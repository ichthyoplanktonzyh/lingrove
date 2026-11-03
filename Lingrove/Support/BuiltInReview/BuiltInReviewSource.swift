import LingroveNotebook
import LingroveNotebookEngine

/// Label/navigation projection only. The actual enrollment and Card source keep their frozen
/// identity, so a moved example or renamed expression cannot silently retarget a practice record.
enum BuiltInReviewSource {
    static func value(_ selection: VocabularySelection, in scope: LingroveNotebookSnapshot)
        -> (entry: VocabularyEntry, sense: VocabularySense)? {
        for entry in scope.document.entries {
            if let sense = entry.senses.first(where: { $0.id == selection.senseID || $0.mergedFrom.contains(selection.senseID) }) {
                return (entry, sense)
            }
        }
        return nil
    }
}
