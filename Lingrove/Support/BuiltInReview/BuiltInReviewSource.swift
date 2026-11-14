import LingroveNotebook
import LingroveNotebookEngine

/// Label/navigation projection only. The actual enrollment and Card source keep their frozen
/// identity, so a consolidated sense or renamed expression cannot silently retarget a practice record.
enum BuiltInReviewSource {
    static func value(_ selection: VocabularySelection, in scope: LingroveNotebookSnapshot)
        -> (entry: VocabularyEntry, sense: VocabularySense)? {
        // Resolve IDs from headers before joining evidence for this one entry. Accessing
        // document.entries here would rebuild all examples on every card redraw.
        guard let header = scope.document.catalog.first(where: {
            $0.senses.contains { $0.id == selection.senseID || $0.mergedFrom.contains(selection.senseID) }
        }), let entry = VocabularyNotebookProjection.entry(header.id, in: scope.document),
              let sense = entry.senses.first(where: { $0.id == selection.senseID || $0.mergedFrom.contains(selection.senseID) }) else {
            return nil
        }
        return (entry, sense)
    }
}
