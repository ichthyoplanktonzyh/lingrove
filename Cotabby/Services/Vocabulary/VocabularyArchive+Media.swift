import Foundation

/// Media operations share the archive actor's transaction ordering. Encoding/decoding, image
/// normalization and file IO therefore never run on MainActor. Immutable resources are written
/// first, JSON is the commit point, and failed commits remove only newly introduced resources.
extension VocabularyArchive {
    func validateBlockIdentities(_ blocks: [VocabularyContentBlock], ids: inout Set<UUID>) throws {
        for block in blocks { guard ids.insert(block.id).inserted else { throw VocabularyError.invalidArchive } }
    }
    static let maximumBackupBytes = 192 * 1_024 * 1_024
    static let maximumMediaBytes = 128 * 1_024 * 1_024

    static func imageReferences(_ document: VocabularyDocument) -> [VocabularyImageReference] {
        document.entries.flatMap { $0.senses.flatMap { VocabularyContentPolicy.images($0.content ?? []) } }
    }

    func prepareImage(_ data: Data) throws -> VocabularyPreparedImage { try VocabularyImageStorage.prepare(data) }

    func prepareImage(at url: URL) throws -> VocabularyPreparedImage {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count <= 24 * 1_024 * 1_024 else {
            throw VocabularyError.invalidContent
        }
        return try prepareImage(VocabularyImageStorage.boundedRead(url, maximum: 24 * 1_024 * 1_024))
    }

    func image(_ reference: VocabularyImageReference) throws -> Data { try images.read(reference) }

    func commitWithImages(_ next: VocabularyDocument, supplied: [String: Data]) throws -> VocabularySnapshot {
        // An edited sentence still carries its old explanation until commit normalizes it.
        // Validate media before staging, then let commit prune stale AI records and validate
        // the complete graph. Premature whole-document validation rejects legitimate edits.
        for entry in next.entries {
            for sense in entry.senses { try VocabularyContentPolicy.validate(sense.content ?? []) }
        }
        let references = Self.imageReferences(next)
        guard references.reduce(0, { $0 + $1.byteCount }) <= Self.maximumMediaBytes else { throw VocabularyError.oversizedArchive }
        let existing = Set(Self.imageReferences(try load().document))
        var written: [VocabularyImageReference] = []
        do {
            for image in Set(references) {
                if let data = supplied[image.filename] {
                    if try images.write(data, image: image) { written.append(image) }
                } else if !existing.contains(image) {
                    _ = try images.read(image)
                }
            }
            return try commit(next)
        } catch {
            for image in written { images.remove(image) }
            throw error
        }
    }

    func backup(to destination: URL) throws {
        try validateBackupDestination(destination)
        let document = try load().document
        var media: [String: Data] = [:]
        for image in Set(Self.imageReferences(document)) { media[image.filename] = try images.read(image) }
        guard media.values.reduce(0, { $0 + $1.count }) <= Self.maximumMediaBytes else { throw VocabularyError.oversizedArchive }
        let data = try JSONEncoder().encode(VocabularyBackup(document: document, images: media))
        guard data.count <= Self.maximumBackupBytes else { throw VocabularyError.oversizedArchive }
        try writeAtomically(data, to: destination)
    }

    /// The UI confirms replacement before entering this synchronous actor transaction. Validate
    /// the whole package before writing anything, so malformed/missing media leaves the current
    /// notebook intact. Stable sense IDs and Anki receipts are restored together with the content.
    func restore(from source: URL) throws -> VocabularySnapshot {
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
        return try commitWithImages(backup.document, supplied: backup.images)
    }

    func validateBackupDestination(_ destination: URL) throws {
        let path = destination.resolvingSymlinksInPath().standardizedFileURL.path
        if let url, path == url.resolvingSymlinksInPath().standardizedFileURL.path { throw VocabularyError.invalidContent }
        if let directory = images.directory?.resolvingSymlinksInPath().standardizedFileURL.path,
           path == directory || path.hasPrefix(directory + "/") { throw VocabularyError.invalidContent }
    }
}
