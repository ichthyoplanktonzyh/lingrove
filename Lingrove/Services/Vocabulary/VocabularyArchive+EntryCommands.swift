import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The archive owns command orchestration on its serialized connection. Cold text commands
/// first try a certified local commit; missing proof or broader dependencies use full
/// preparation. Warm complete state retains its incremental cache and complete UI receipt.
extension VocabularyArchive {
    func saveIncrementally(_ capture: VocabularyCapture) throws -> VocabularyArchiveMutation {
        try storageAccess(write: true) {
            if hasCompleteBaseline { return .complete(try save(capture)) }
            let engine = try persistence()
            guard let version = try engine.currentNotebookVersion() else { return .complete(try save(capture)) }
            try checkCommandOwner(version)
            let detail = try engine.notebookEntryDetail(lookupKey: VocabularyPolicy.entryKey(capture))
            // Another connection can replace the active owner between the metadata and
            // detail transactions. The prepared draft must keep the caller's original owner.
            try checkCommandOwner(detail.fence.version)
            let entry = try VocabularyPolicy.entryForSave(capture, existing: detail.entry, now: Date())
            if let saved = try engine.trySaveNotebookEntry(entry, basedOn: detail.fence.version) { return .entry(saved) }
            return .complete(try save(capture))
        }
    }

    func removeSenseIncrementally(entryID: UUID, senseID: UUID) throws -> VocabularyArchiveMutation {
        try storageAccess(write: true) {
            if hasCompleteBaseline { return .complete(try removeSense(entryID: entryID, senseID: senseID)) }
            let engine = try persistence()
            if let version = try engine.currentNotebookVersion() {
                try checkCommandOwner(version)
                if let saved = try engine.tryRemoveNotebookSense(senseID, from: entryID, basedOn: version) { return .entry(saved) }
            }
            return .complete(try removeSense(entryID: entryID, senseID: senseID))
        }
    }
}
