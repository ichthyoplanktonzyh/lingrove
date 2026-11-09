import LingroveNotebook
import Foundation

/// Explicit manual drafts are validated and saved on the existing archive actor. The write
/// transaction preserves concurrent headword additions without inferring equivalent senses.
extension VocabularyArchive {
    func addEntries(_ inputs: [VocabularyEntryInput]) throws -> (VocabularyArchiveSnapshot, VocabularyEntryImportResult) {
        try storageAccess(write: true) {
            try Task.checkCancellation()
            let snapshot = try load()
            let plan = try VocabularyEntryInputPolicy.plan(inputs, into: snapshot.document, now: Date())
            try Task.checkCancellation()
            guard plan.result.hasChanges else { return (snapshot, plan.result) }
            return (try commit(plan.document), plan.result)
        }
    }

}
