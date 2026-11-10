import Foundation
import LingroveNotebook

typealias CLIExample = NotebookCaptureExample
typealias CLIJSON = NotebookToolJSON
typealias CLIError = NotebookToolError
typealias CLICapture = NotebookCaptureTask

/// Versioned values shared by the bundled command-line executable and app. The executable only
/// transports these values: domain validation and all notebook writes remain inside the app.
nonisolated struct CLIRequest: Codable, Sendable {
    enum Command: String, Codable, Sendable { case hello, status, list, get, sense, readMany, image, apply, resourceList, resourceGet }
    var version = CLIServiceIdentity.protocolVersion
    var id = UUID()
    var expiresAt = Date().addingTimeInterval(30)
    var command: Command
    var query: String?
    var language: String?
    var limit: Int?
    var offset: Int?
    var entryID: UUID?
    var senseID: UUID?
    var imageID: String?
    var readScope: CLINotebookScope?
    var readSelection: CLIReadSelection?
    var resource: String?
    var resourceID: UUID?
    var relatedID: UUID?
    var claimStatus: String?
    var summary: Bool?
    var serverInstanceID: UUID?
    var targetAppPath: String?
    var batch: CLIBatch?
    var dryRun = false
}

/// One request selects one kind of material in caller order. CLI parsing and the archive both
/// validate this short-lived value; the archive resolves all IDs against one immutable snapshot.
nonisolated struct CLIReadSelection: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case entries, senses }
    static let maximumIDs = 100
    var kind: Kind
    var ids: [UUID]

    func validate() throws {
        guard (1...Self.maximumIDs).contains(ids.count), Set(ids).count == ids.count else {
            throw CLIError.invalid("Batch reads require 1–100 distinct IDs of one kind.")
        }
    }
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
    var merge: CLIMerge?
    var remove: CLIRemoveSense?
}

typealias CLIResourcePut = NotebookResourcePut
typealias CLIResourceDelete = NotebookResourceDelete

/// Explicit consolidation chooses a surviving sense; the app never classifies meanings.
/// The batch supplies the notebook scope and revision for this destructive structural edit.
nonisolated struct CLIMerge: Codable, Sendable {
    var entryID: UUID
    var sourceSenseID: UUID
    var targetSenseID: UUID

    static let shape = CLIResourceContract.Shape(fields: ["entryID": .uuid,
        "sourceSenseID": .uuid, "targetSenseID": .uuid],
        required: ["entryID", "sourceSenseID", "targetSenseID"])
}

/// Removing a sense is a domain operation: its examples/links are detached atomically while
/// shared nodes and independent source evidence survive. An empty headword is removed with it.
nonisolated struct CLIRemoveSense: Codable, Sendable {
    var entryID: UUID
    var senseID: UUID
    static let shape = CLIResourceContract.Shape(fields: ["entryID": .uuid, "senseID": .uuid], required: ["entryID", "senseID"])
}

/// A request-local addition connects a sense to an existing shared node. The planner derives
/// relation kind from that node and keeps any explanation on the sense itself.
nonisolated struct CLISenseLink: Codable, Sendable {
    var nodeID: UUID
    var conditions: String?
}

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
    var explanation: String?
    var contentEdits: [VocabularyContentEdit]?
    var exampleEdits: [NotebookExampleEdit]?
    var removeExamples: [UUID]?
    var linkNodes: [CLISenseLink]?
    var unlinkNodes: [UUID]?
    var meaning: String?
    var meaningLanguage: String?
    var note: String?
    var tags: [String]?
}

extension CLIUpdate {
    /// One descriptor feeds the executable schema and app validation for nested sense edits.
    nonisolated static let editFields: [String: CLIResourceContract.Field] = [
        "contentEdits": .array(.object(.init(fields: ["blockID": .uuid, "find": .text(262_144),
            "replacement": .text(262_144), "caption": .text(16_384), "remove": .bool], required: ["blockID"])), 64),
        "exampleEdits": .array(.object(NotebookCaptureContract.exampleEdit), 100),
        "removeExamples": .array(.uuid, 100),
        "linkNodes": .array(.object(.init(fields: ["nodeID": .uuid, "conditions": .text(8_192)], required: ["nodeID"])), 64),
        "unlinkNodes": .array(.uuid, 64)
    ]
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
    var version = CLIServiceIdentity.protocolVersion
    var requestID: UUID
    var ok: Bool
    var result: CLIJSON?
    var error: CLIError?
    var server: CLIServiceIdentity?
    static func failure(_ id: UUID, _ error: CLIError) -> Self { .init(requestID: id, ok: false, error: error) }
}
