import Darwin
import Foundation
import LingroveNotebookEngine

// The caller owns the backup and supplies a staged copy of the closed Dev database.
// Requiring explicit paths keeps this tool away from any installed app by default.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: lingrove-dev-corpus-migration <copied database> <media directory>\n".utf8))
    exit(64)
}
let database = URL(fileURLWithPath: arguments[0])
let media = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard FileManager.default.fileExists(atPath: database.path) else {
    FileHandle.standardError.write(Data("The staged database does not exist.\n".utf8))
    exit(66)
}
do {
    let count = try LingroveNotebookStore.migrateDevCorpus(databaseURL: database, mediaDirectoryURL: media)
    print("Migrated corpus entries: \(count)")
} catch {
    FileHandle.standardError.write(Data("Dev corpus migration failed: \(error)\n".utf8))
    exit(1)
}
