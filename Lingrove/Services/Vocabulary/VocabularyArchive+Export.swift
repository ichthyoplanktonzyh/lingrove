import LingroveNotebookStorage
import LingroveNotebookEngine
import LingroveStudyExport
import Foundation
import LingroveNotebook

/// The archive serializes snapshot and media reads with edits/GC. The returned immutable package
/// owns all selected bytes, so later source deletion cannot change a preview or its saved file.
extension VocabularyArchive {
    func prepareExport(selections: [VocabularySelection], configuration: VocabularyExportConfiguration) throws -> VocabularyExportPackage {
        try storageAccess(write: false) {
            guard let scope = try load().scope else { throw VocabularyError.editConflict }
            let core = try persistence().core
            let binding = try LingroveNotebookBackupStore(core: core).capture(scope)
            let package = try LingroveNotebookStudyExportStore(core: core).read(binding: binding, selections: selections,
                configuration: configuration)
            try Task.checkCancellation()
            return package
        }
    }

    func writeExport(_ package: VocabularyExportPackage, to destination: URL) throws {
        try Task.checkCancellation()
        try validateBackupDestination(destination)
        let data = try package.configuration.includesImages ? VocabularyExportZIP.data(package) : package.data
        guard data.count <= Self.maximumBackupBytes else { throw VocabularyExportError.tooLarge }
        try writeAtomically(data, to: destination, cancellable: true)
    }
}
