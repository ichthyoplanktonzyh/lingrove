import Foundation
@testable import LingroveNotebookEngine

// These old test call labels now name the portable facade. Production Mac code always supplies
// the media root explicitly; only this synthetic test adapter colocates it beside the SQLite file.
typealias LocalDatabase = LingroveNotebookEngine
extension LingroveNotebookEngine {
    convenience init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, mediaDirectoryURL: databaseURL.deletingLastPathComponent())
    }
}
