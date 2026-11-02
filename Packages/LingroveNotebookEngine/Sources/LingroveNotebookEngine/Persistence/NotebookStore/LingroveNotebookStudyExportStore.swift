import Foundation
import LingroveNotebook
import LingroveStudyExport

/// Borrows the primary SQLite core without changing the notebook. The worker
/// freezes the chosen projection and its owned PNG bytes in one read transaction;
/// formatters can then work without retaining a database lock or a live document.
public nonisolated struct LingroveNotebookStudyExportStore {
    public let core: DatabaseCore

    public func read(binding: LingroveNotebookBackupBinding, selections: [VocabularySelection],
              collectedOnly: Bool, configuration: VocabularyExportConfiguration) throws -> VocabularyExportPackage {
        let frozen = try core.inReadTransaction {
            let admission = LingroveNotebookBackupStore(core: core)
            try admission.checkInTransaction(binding)
            let snapshot = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: binding.workspaceId)
            let entries = try VocabularyExportPolicy.selected(
                collectedOnly ? snapshot.document.collectedEntries : snapshot.document.entries, selections: selections)
            let references = VocabularyExportPolicy.images(entries, configuration: configuration)
            guard references.reduce(0, { $0 + $1.byteCount }) <= VocabularyDocumentValidation.maximumMediaBytes else {
                throw VocabularyExportError.tooLarge
            }
            var images: [String: Data] = [:]
            let media = LingroveNotebookMediaStore(core: core)
            for reference in references.sorted(by: { $0.filename < $1.filename }) {
                try Task.checkCancellation()
                do { images[reference.filename] = try media.imageInTransaction(reference, scope: snapshot, requireActiveWorkspace: true) }
                catch is CancellationError { throw CancellationError() }
                catch { throw VocabularyExportError.missingImage }
            }
            try admission.checkInTransaction(binding)
            return (entries, images, snapshot.document.semantics, snapshot.document.classification)
        }
        var package = try VocabularyExportPolicy.package(frozen.0, configuration: configuration,
            semantics: frozen.2, classification: frozen.3)
        package.images = frozen.1
        return package
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
