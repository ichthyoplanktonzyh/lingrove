import LingroveNotebookStorage
import LingroveNotebookEngine
import LingroveNotebook
import Foundation

/// The archive handles bounded file decoding away from MainActor. Media reads and registration
/// borrow the engine's workspace authorization and content-addressed cache. An image's digest
/// alone grants no access, and removing one collection cannot delete another workspace's bytes.
extension VocabularyArchive {
    static let maximumBackupBytes = VocabularyDocumentValidation.maximumBackupBytes
    static let maximumMediaBytes = VocabularyDocumentValidation.maximumMediaBytes

    static func imageReferences(_ document: VocabularyDocument) -> [VocabularyImageReference] {
        VocabularyDocumentValidation.imageReferences(document)
    }

    func prepareImage(_ data: Data) throws -> VocabularyPreparedImage { try VocabularyImageStorage.prepare(data) }

    func prepareImage(at url: URL) throws -> VocabularyPreparedImage {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count <= 24 * 1_024 * 1_024 else {
            throw VocabularyError.invalidContent
        }
        return try prepareImage(VocabularyImageStorage.boundedRead(url, maximum: 24 * 1_024 * 1_024))
    }

    func image(_ reference: VocabularyImageReference) throws -> Data {
        try storageAccess(write: false) {
            let snapshot = try load()
            guard let scope = snapshot.scope else { throw VocabularyError.editConflict }
            guard Self.imageReferences(snapshot.document).contains(reference) else { throw VocabularyError.invalidContent }
            return try LingroveNotebookMediaStore(core: persistence().core).image(reference, scope: scope, requireActiveWorkspace: true)
        }
    }

    /// Read the before-image without refreshing the archive's save baseline. An external
    /// writer during media IO must make the later merge fail its original revision check.
    func imagesForUndo(_ references: Set<VocabularyImageReference>, scope: VocabularyOperationScope) throws -> [String: Data] {
        let media = LingroveNotebookMediaStore(core: try persistence().core)
        var result: [String: Data] = [:]
        for reference in references {
            result[reference.filename] = try media.image(reference, scope: scope, requireActiveWorkspace: true)
        }
        return result
    }

    func commitWithImages(
        _ next: VocabularyDocument, supplied: [String: Data], receipt: VocabularyCLIReceipt? = nil, restoringBackup: Bool = false
    ) throws -> VocabularyArchiveSnapshot {
        try Task.checkCancellation()
        return try commitUsingEngine(next, images: supplied, receipt: receipt, restoringBackup: restoringBackup)
    }

    func backup(to destination: URL) throws {
        try validateBackupDestination(destination)
        let backup = try storageAccess(write: false) {
            guard let scope = try load().scope else { throw VocabularyError.editConflict }
            let backupStore = LingroveNotebookBackupStore(core: try persistence().core)
            return try backupStore.read(backupStore.capture(scope))
        }
        let data = try JSONEncoder().encode(backup)
        guard data.count <= Self.maximumBackupBytes else { throw VocabularyError.oversizedArchive }
        try Task.checkCancellation()
        try writeAtomically(data, to: destination, cancellable: true)
    }

    /// Restore validates a complete portable backup before saving. The replacement leaves the
    /// notebook intact on failure. Stable sense IDs and optional Anki receipts return with the content; the
    /// engine refreshes built-in material without replacing its scheduling/history tables.
    func restore(from source: URL) throws -> VocabularyArchiveSnapshot {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count <= Self.maximumBackupBytes else {
            throw VocabularyError.oversizedArchive
        }
        let backup = try JSONDecoder().decode(VocabularyBackup.self,
            from: VocabularyImageStorage.boundedRead(source, maximum: Self.maximumBackupBytes))
        guard backup.version == 1 else { throw VocabularyError.unsupportedVersion }
        try validate(backup.document)
        let references = Set(Self.imageReferences(backup.document))
        guard Set(references.map(\.filename)) == Set(backup.images.keys),
              backup.images.values.reduce(0, { $0 + $1.count }) <= Self.maximumMediaBytes else { throw VocabularyError.invalidArchive }
        for image in references {
            guard let data = backup.images[image.filename] else { throw VocabularyError.invalidArchive }
            try VocabularyImageStorage.validate(data, reference: image)
        }
        return try commitWithImages(backup.document, supplied: backup.images, restoringBackup: true)
    }

    func validateBackupDestination(_ destination: URL) throws {
        let path = destination.resolvingSymlinksInPath().standardizedFileURL.path
        if let url {
            for suffix in ["", "-wal", "-shm", "-journal", ".lock"] {
                let protected = URL(fileURLWithPath: url.path + suffix).resolvingSymlinksInPath().standardizedFileURL.path
                if path == protected || Self.sameFile(destination, URL(fileURLWithPath: protected)) {
                    throw VocabularyError.invalidContent
                }
            }
        }
        let directory = mediaDirectoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        if path == directory || path.hasPrefix(directory + "/") { throw VocabularyError.invalidContent }
    }

    /// Resolving symlinks does not detect hard links. Replacing a live database or WAL through
    /// another name must be rejected just as replacing its canonical path is rejected.
    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        guard let lhs = try? FileManager.default.attributesOfItem(atPath: first.path),
              let rhs = try? FileManager.default.attributesOfItem(atPath: second.path),
              let inode = lhs[.systemFileNumber] as? NSNumber, let device = lhs[.systemNumber] as? NSNumber else { return false }
        return inode == rhs[.systemFileNumber] as? NSNumber && device == rhs[.systemNumber] as? NSNumber
    }
}
