import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookStorage

/// Shared fixture loading keeps each storage test focused on a behavior. The historical SQLite
/// resource is copied to a unique temporary directory because opening it enables WAL mode.
enum VocabularyStorageTestSupport {
    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingroveNotebookStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func copiedSchema5Fixture(to directory: URL) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "schema5-synthetic", withExtension: "sqlite", subdirectory: "Fixtures"))
        let destination = directory.appendingPathComponent("schema5-synthetic.sqlite")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func lexicalDocument(_ expression: String) -> VocabularyDocument {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = VocabularyEntry(id: id, expression: expression, dictionaryForm: expression,
            language: .english, kind: .word, senses: [], createdAt: date, updatedAt: date)
        return VocabularyDocument(entries: [entry])
    }
}
