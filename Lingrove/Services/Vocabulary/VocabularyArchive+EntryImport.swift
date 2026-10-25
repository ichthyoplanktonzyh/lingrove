import Foundation

/// File decoding and batch planning run on the existing archive actor, away from SwiftUI.
/// Confirmation re-plans under the SQLite write lock, preserving edits made since the preview.
extension VocabularyArchive {
    func readWordList(at source: URL) throws -> VocabularyWordList {
        try Task.checkCancellation()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let count = values.fileSize,
              count <= VocabularyWordListPolicy.maximumBytes else { throw VocabularyWordListError.tooLarge }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: VocabularyWordListPolicy.maximumBytes + 1) ?? Data()
        try Task.checkCancellation()
        return try VocabularyWordListPolicy.decode(data, fileExtension: source.pathExtension)
    }

    func previewWordList(_ table: VocabularyWordList, configuration: VocabularyWordListConfiguration) throws -> VocabularyWordListPreview {
        let inputs = try VocabularyWordListPolicy.inputs(table, configuration: configuration)
        let plan = try VocabularyEntryInputPolicy.plan(inputs, into: load().document, now: Date())
        return .init(inputs: inputs, result: plan.result)
    }

    func addEntries(_ inputs: [VocabularyEntryInput]) throws -> (VocabularySnapshot, VocabularyEntryImportResult) {
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
