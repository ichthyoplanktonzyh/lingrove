import Foundation
import LingroveNotebook

/// The app-owned store owns this serial projection worker. Joining source evidence and hashing
/// capture keys happens once per accepted revision away from MainActor. Only the immutable index
/// crosses back; the store rechecks scope/revision before publishing it.
actor VocabularyReadIndexWorker {
    func prepare(_ snapshot: VocabularyArchiveSnapshot) -> VocabularyReadIndex {
        VocabularyReadIndex(entries: snapshot.joinedEntries ?? snapshot.document.entries)
    }
}
