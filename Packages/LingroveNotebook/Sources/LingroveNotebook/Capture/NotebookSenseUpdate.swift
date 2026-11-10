import Foundation

/// One request names an existing sense and its expected document revision. Native CLI and
/// mobile tools decode this same contract; their hosts own scope admission and persistence.
public nonisolated struct NotebookSenseUpdate: Codable, Sendable {
    public var entryID: UUID
    public var senseID: UUID
    public var expectedRevision: UInt64
    public var explanation: String?
    public var contentEdits: [VocabularyContentEdit]?
    public var exampleEdits: [NotebookExampleEdit]?
    public var removeExamples: [UUID]?
    public var linkNodes: [NotebookSenseLink]?
    public var unlinkNodes: [UUID]?
    public var meaning: String?
    public var meaningLanguage: String?
    public var note: String?
    public var tags: [String]?
    public init(entryID: UUID,
        senseID: UUID,
        expectedRevision: UInt64,
        explanation: String? = nil,
        contentEdits: [VocabularyContentEdit]? = nil,
        exampleEdits: [NotebookExampleEdit]? = nil,
        removeExamples: [UUID]? = nil,
        linkNodes: [NotebookSenseLink]? = nil,
        unlinkNodes: [UUID]? = nil,
        meaning: String? = nil,
        meaningLanguage: String? = nil,
        note: String? = nil,
        tags: [String]? = nil) {
        self.entryID = entryID
        self.senseID = senseID
        self.expectedRevision = expectedRevision
        self.explanation = explanation
        self.contentEdits = contentEdits
        self.exampleEdits = exampleEdits
        self.removeExamples = removeExamples
        self.linkNodes = linkNodes
        self.unlinkNodes = unlinkNodes
        self.meaning = meaning
        self.meaningLanguage = meaningLanguage
        self.note = note
        self.tags = tags
    }
}

/// A link adopts an existing reusable node without putting explanation text on the relation.
public nonisolated struct NotebookSenseLink: Codable, Sendable {
    public var nodeID: UUID
    public var conditions: String?
    public init(nodeID: UUID, conditions: String? = nil) { self.nodeID = nodeID; self.conditions = conditions }
}

extension NotebookSenseUpdate {
    /// One descriptor feeds the executable schema and app validation for nested sense edits.
    public static let editFields: [String: NotebookResourceContract.Field] = [
        "contentEdits": .array(.object(.init(fields: ["blockID": .uuid, "find": .text(262_144),
            "replacement": .text(262_144), "caption": .text(16_384), "remove": .bool], required: ["blockID"])), 64),
        "exampleEdits": .array(.object(NotebookCaptureContract.exampleEdit), 100),
        "removeExamples": .array(.uuid, 100),
        "linkNodes": .array(.object(.init(fields: ["nodeID": .uuid, "conditions": .text(8_192)], required: ["nodeID"])), 64),
        "unlinkNodes": .array(.uuid, 64)
    ]
    public static var shape: NotebookToolShape.Shape {
        var fields: [String: NotebookToolShape.Field] = [
            "entryID": .uuid, "senseID": .uuid, "expectedRevision": .integer,
            "meaning": .text(32_000), "meaningLanguage": .text(100), "explanation": .text(262_144),
            "note": .text(262_144), "tags": .array(.text(200), 100)
        ]
        fields.merge(editFields) { _, new in new }
        return .init(fields: fields, required: ["entryID", "senseID", "expectedRevision"])
    }

    public static func decode(_ value: NotebookToolJSON) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(shape.normalized(value)))
    }
}
