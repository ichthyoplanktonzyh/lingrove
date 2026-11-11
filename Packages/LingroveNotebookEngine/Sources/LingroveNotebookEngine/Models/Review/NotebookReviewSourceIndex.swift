import Foundation
import LingroveNotebook

/// One material refresh owns this immutable lookup for its saved notebook revision. Reusing
/// the already joined entries turns refreshing many Notes into one corpus join plus direct
/// lookups. Historical sense aliases follow the same live owner as source navigation; neither
/// the index nor a caller can change a Card's scheduling/history or manufacture missing input.
struct NotebookReviewSourceIndex {
    private let entries: [VocabularyEntry]
    private let owners: [UUID: (entry: Int, sense: Int)]

    init(entries: [VocabularyEntry]) {
        self.entries = entries
        var owners: [UUID: (entry: Int, sense: Int)] = [:]
        for (entryIndex, entry) in entries.enumerated() {
            for (senseIndex, sense) in entry.senses.enumerated() {
                for id in [sense.id] + sense.mergedFrom {
                    owners[id] = (entryIndex, senseIndex)
                }
            }
        }
        self.owners = owners
    }

    func source(for note: ReviewNote) -> (VocabularyEntry, VocabularySense)? {
        guard let owner = owners[note.senseID] else { return nil }
        let entry = entries[owner.entry]
        return (entry, entry.senses[owner.sense])
    }
}
