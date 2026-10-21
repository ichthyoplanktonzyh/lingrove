import Foundation

/// The archive serializes snapshot and media reads with edits/GC. The returned immutable package
/// owns all selected bytes, so later source deletion cannot change a preview or its saved file.
extension VocabularyArchive {
    func prepareExport(selections: [VocabularySelection], configuration: VocabularyExportConfiguration) throws -> VocabularyExportPackage {
        let selected = try VocabularyExportPolicy.selected(load().document.entries, selections: selections)
        var package = try VocabularyExportPolicy.package(selected, configuration: configuration)
        let references = VocabularyExportPolicy.images(selected, configuration: configuration)
        guard references.reduce(0, { $0 + $1.byteCount }) <= Self.maximumMediaBytes else { throw VocabularyExportError.tooLarge }
        for reference in references {
            try Task.checkCancellation()
            do { package.images[reference.filename] = try images.read(reference) } catch { throw VocabularyExportError.missingImage }
        }
        try Task.checkCancellation()
        return package
    }

    func writeExport(_ package: VocabularyExportPackage, to destination: URL) throws {
        try Task.checkCancellation()
        try validateBackupDestination(destination)
        let data = try package.configuration.includesImages ? VocabularyExportZIP.data(package) : package.data
        guard data.count <= Self.maximumBackupBytes else { throw VocabularyExportError.tooLarge }
        try writeAtomically(data, to: destination, cancellable: true)
    }
}
