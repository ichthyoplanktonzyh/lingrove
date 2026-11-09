import Foundation
import LingroveNotebook

/// One closed task descriptor produces both validation and `schema capture`. Keeping schema
/// and parsing together prevents a misspelled association or default from being discarded by
/// Codable. This module depends only on wire values, so app and client use identical rules.
nonisolated enum CLICaptureContract {
    static var shape: CLIResourceContract.Shape { NotebookCaptureContract.shape }
    private static var document: CLIResourceContract.Shape {
        // Header is separate from material so it cannot become stored learning data.
        .init(fields: shape.fields.merging(["version": .integer, "idempotencyKey": .text(200),
            "expectedRevision": .integer, "notebookScope": .object(CLINotebookScope.shape)]) { _, new in new },
            required: ["version", "idempotencyKey", "entries"])
    }

    /// These conditions mirror the optional scope's admission without making a pure new
    /// capture depend on an account. Both published schemas reuse this same descriptor.
    static var existingReferenceCondition: [String: Any] {
        ["anyOf": [
            ["required": ["meanings"], "properties": ["meanings": ["contains": ["required": ["id"]]]]],
            ["required": ["entries"], "properties": ["entries": ["contains": ["properties": [
                "senses": ["contains": ["required": ["id"]]]]]]]]
        ]]
    }

    static var schema: [String: Any] {
        var root = document.schema
        var properties = root["properties"] as? [String: Any] ?? [:]
        properties["version"] = ["const": 1]
        root["properties"] = properties
        root["allOf"] = [
            ["if": ["required": ["expectedRevision"]], "then": ["required": ["notebookScope"]]],
            ["if": existingReferenceCondition, "then": ["required": ["notebookScope"]]]
        ]
        root["x-existingRecordIDsRequireNotebookScope"] = true
        root["title"] = "Lingrove capture task v1"
        root["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        return root
    }

    static func decode(_ data: Data) throws -> CLIBatch {
        guard data.count <= CLIInputPolicy.maximumBytes else { throw CLIError.invalid("Input exceeds 32 MiB.") }
        do {
            guard case var .object(fields) = try JSONDecoder().decode(CLIJSON.self, from: data),
                  case .integer(1)? = fields.removeValue(forKey: "version"),
                  case let .string(key)? = fields.removeValue(forKey: "idempotencyKey") else {
                throw CLIError.invalid("Capture needs version 1 and idempotencyKey. Run 'lingrove schema capture'.")
            }
            let revision: UInt64?
            if let supplied = fields.removeValue(forKey: "expectedRevision") {
                guard case let .integer(number) = supplied, number >= 0 else { throw CLIError.invalid("Invalid expectedRevision.") }
                revision = UInt64(number)
            } else { revision = nil }
            let scope: CLINotebookScope?
            if let supplied = fields.removeValue(forKey: "notebookScope") {
                let value = try CLINotebookScope.shape.normalized(supplied)
                scope = try JSONDecoder().decode(CLINotebookScope.self, from: JSONEncoder().encode(value))
            } else { scope = nil }
            let material = try shape.normalized(.object(fields))
            let capture = try JSONDecoder().decode(CLICapture.self, from: JSONEncoder().encode(material))
            let batch = CLIBatch(version: 2, idempotencyKey: key, expectedRevision: revision,
                notebookScope: scope, operations: [.init(capture: capture)])
            try CLIInputPolicy.validate(batch)
            return batch
        } catch let error as CLIError { throw error } catch {
            throw CLIError.invalid("Invalid capture JSON. Run 'lingrove schema capture'.")
        }
    }

    static func validate(_ capture: CLICapture) throws {
        try NotebookCaptureContract.validate(capture)
    }
}
