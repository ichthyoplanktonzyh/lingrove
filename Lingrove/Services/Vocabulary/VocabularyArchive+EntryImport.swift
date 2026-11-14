import LingroveNotebook
import LingroveNotebookEngine
import Foundation

/// Explicit manual drafts are validated and saved on the existing archive actor. The write
/// transaction preserves concurrent headword additions without inferring equivalent senses.
extension VocabularyArchive {
    func addEntries(_ inputs: [VocabularyEntryInput]) throws -> (VocabularyArchiveSnapshot, VocabularyEntryImportResult) {
        try storageAccess(write: true) {
            try Task.checkCancellation()
            let snapshot = try load()
            let validated = try inputs.map(VocabularyEntryInputPolicy.validated)
            let keys = Set(validated.map {
                VocabularyIdentityPolicy.entryKey(expression: $0.expression, language: $0.language, kind: $0.kind)
            })
            let existing = (snapshot.joinedEntries ?? snapshot.document.entries).filter {
                keys.contains(VocabularyIdentityPolicy.entryKey($0))
            }
            let plan = try VocabularyEntryInputPolicy.batch(inputs, existing: existing, now: Date())
            try Task.checkCancellation()
            guard plan.result.hasChanges else { return (snapshot, plan.result) }
            guard let scope = snapshot.scope else { throw VocabularyError.invalidArchive }
            let saved = try persistence().saveNotebookEntries(plan.entries, basedOn: scope)
            return (try acknowledgeEntryBatch(saved), plan.result)

        }
    }

}
