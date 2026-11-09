import Foundation

/// A resource change targets an existing or explicitly identified record.
public nonisolated struct NotebookResourcePut: Codable, Sendable {
    public let resource: String
    public let value: NotebookToolJSON

    public init(resource: String, value: NotebookToolJSON) {
        self.resource = resource
        self.value = value
    }
}

public nonisolated struct NotebookResourceDelete: Codable, Sendable {
    public let resource: String
    public let id: UUID

    public init(resource: String, id: UUID) {
        self.resource = resource
        self.id = id
    }
}
