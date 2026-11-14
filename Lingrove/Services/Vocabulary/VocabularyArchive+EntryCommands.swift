import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The archive owns command orchestration on its serialized connection. Cold entry commands
/// first try a certified local commit; missing proof or broader dependencies use full
/// preparation. Warm complete state retains its incremental cache and complete UI receipt.
extension VocabularyArchive {
    func updateIncrementally(_ entry: VocabularyEntry, basedOn baseline: VocabularyEntry,
                             importedImages: [String: Data]) throws -> VocabularyArchiveMutation {
        try editIncrementally(entryID: entry.id, images: importedImages, preparing: {
            try self.mergedEntry(entry, baseline: baseline, current: $0)
        }, fallback: { try self.update(entry, basedOn: baseline, importedImages: importedImages) })
    }

    /// The archive borrows one lossless detail read, prepares a draft and admits its exact
    /// fence at commit. It retains no partial document as a complete baseline. A warm full
    /// consumer or missing certificate uses the existing full transaction and receipt.
    private func editIncrementally(entryID: UUID, images: [String: Data] = [:],
                                   preparing: (VocabularyEntry) throws -> VocabularyEntry,
                                   fallback: () throws -> VocabularyArchiveSnapshot) throws -> VocabularyArchiveMutation {
        try storageAccess(write: true) {
            if hasCompleteBaseline { return .complete(try fallback()) }
            let engine = try persistence()
            if let version = try engine.currentNotebookVersion() {
                try checkCommandOwner(version)
                let detail = try engine.notebookEntryDetail(entryID: entryID)
                try checkCommandOwner(detail.fence.version)
                guard let current = detail.entry else { throw VocabularyError.editConflict }
                let next = try preparing(current)
                if next.senses.isEmpty { return .complete(try fallback()) }
                if let saved = try engine.trySaveNotebookEntry(next, basedOn: detail.fence.version, images: images) { return .entry(saved) }
            }
            return .complete(try fallback())
        }
    }

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
