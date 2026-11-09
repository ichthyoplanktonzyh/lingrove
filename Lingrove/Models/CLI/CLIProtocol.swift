import Foundation
import LingroveNotebook

typealias CLIExample = NotebookCaptureExample
typealias CLIJSON = NotebookToolJSON
typealias CLIError = NotebookToolError
typealias CLICapture = NotebookCaptureTask

/// Versioned values shared by the bundled command-line executable and app. The executable only
/// transports these values: domain validation and all notebook writes remain inside the app.
nonisolated struct CLIRequest: Codable, Sendable {
    enum Command: String, Codable, Sendable { case status, list, get, apply, resourceList, resourceGet }
    var version = 1
    var id = UUID()
    var expiresAt = Date().addingTimeInterval(30)
    var command: Command
    var query: String?
    var language: String?
    var limit: Int?
    var offset: Int?
    var entryID: UUID?
    var resource: String?
    var resourceID: UUID?
    var relatedID: UUID?
    var claimStatus: String?
    var batch: CLIBatch?
    var dryRun = false
}

/// One idempotency key describes one atomic batch. Appending is distinct from replacing fields,
/// so an agent cannot overwrite a user's meaning or note merely by capturing another example.
nonisolated struct CLIBatch: Codable, Sendable {
    var version: Int
    var idempotencyKey: String
    var expectedRevision: UInt64?
    /// Reads return this complete identity. Existing-record writes retain it instead of rebinding
    /// a delayed command to whichever account happens to be active when the mailbox runs.
    var notebookScope: CLINotebookScope?
    var operations: [CLIChange]
}

nonisolated struct CLINotebookScope: Codable, Equatable, Sendable {
    let workspaceID: String
    let notebookID: UUID
    let generation: String

    static let shape = CLIResourceContract.Shape(fields: ["workspaceID": .text(200), "notebookID": .uuid,
        "generation": .text(200)], required: ["workspaceID", "notebookID", "generation"])
}

nonisolated struct CLIChange: Codable, Sendable {
    var add: CLINewSense?
    var append: CLIAppend?
    var update: CLIUpdate?
    var put: CLIResourcePut?
    var delete: CLIResourceDelete?
    var capture: CLICapture?
}

typealias CLIResourcePut = NotebookResourcePut
typealias CLIResourceDelete = NotebookResourceDelete

nonisolated struct CLINewSense: Codable, Sendable {
    var expression: String
    var language: String
    var kind: String
    var dictionaryForm: String?
    var meaning: String
    var meaningLanguage: String?
    var note: String?
    var tags: [String]?
    var examples: [CLIExample]?
    var content: [CLIBlock]?
}

nonisolated struct CLIAppend: Codable, Sendable {
    var entryID: UUID
    var senseID: UUID
    var examples: [CLIExample]?
    var content: [CLIBlock]?
    var tags: [String]?
}

nonisolated struct CLIUpdate: Codable, Sendable {
    var entryID: UUID
    var senseID: UUID
    var expectedRevision: UInt64
    var meaning: String?
    var meaningLanguage: String?
    var note: String?
    var tags: [String]?
}

/// File paths exist only in CLI input. The executable reads explicitly supplied images and sends
/// bounded bytes; the app never opens an arbitrary path supplied by an automation request.
nonisolated struct CLIBlock: Codable, Sendable {
    var text: String?
    var image: Image?
    var bold: Bool?
    var italic: Bool?
    struct Image: Codable, Sendable {
        var path: String?
        var data: Data?
        var caption: String?
    }
}

nonisolated struct CLIReply: Codable, Sendable {
    var version = 1
    var requestID: UUID
    var ok: Bool
    var result: CLIJSON?
    var error: CLIError?
    static func failure(_ id: UUID, _ error: CLIError) -> Self { .init(requestID: id, ok: false, error: error) }
}
