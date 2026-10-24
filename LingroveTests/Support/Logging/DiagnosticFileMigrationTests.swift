import Foundation
import Testing
@testable import Lingrove

/// Rotation and aliases are checked in private temporary directories. The production logger's
/// singleton is never opened, so these cases cannot rotate or overwrite actual user logs.
struct DiagnosticFileMigrationTests {
    @Test
    func movesExistingBytesAndKeepsTheLegacyPathAsAnAlias() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("cotabby.jsonl")
        try Data("original\n".utf8).write(to: legacy)
        try Data("rotated\n".utf8).write(to: directory.appendingPathComponent("cotabby.jsonl.1"))
        let primary = DiagnosticFileMigration.eventLogURL(in: directory)
        #expect(try Data(contentsOf: primary) == Data("original\n".utf8))
        #expect(try Data(contentsOf: legacy) == Data("original\n".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) == "lingrove.jsonl")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: directory.appendingPathComponent("cotabby.jsonl.1").path) == "lingrove.jsonl.1")
        #expect(try Data(contentsOf: directory.appendingPathComponent("lingrove.jsonl.1")) == Data("rotated\n".utf8))
        #expect(DiagnosticFileMigration.eventLogURL(in: directory) == primary)
    }

    @Test
    func neverOverwritesEitherHistoryWhenBothNamesAlreadyExist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("cotabby.jsonl")
        let primary = directory.appendingPathComponent("lingrove.jsonl")
        try Data("legacy".utf8).write(to: legacy)
        try Data("current".utf8).write(to: primary)
        #expect(DiagnosticFileMigration.eventLogURL(in: directory) == primary)
        #expect(try Data(contentsOf: legacy) == Data("legacy".utf8))
        #expect(try Data(contentsOf: primary) == Data("current".utf8))
    }
}
