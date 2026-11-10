import Foundation

/// Task-shaped input shared by the executable and app. A capture is a short-lived value owned
/// by one batch: callers describe language material and local meaning references, while the
/// app planner owns durable IDs, evidence and graph construction.
public nonisolated struct NotebookCaptureTask: Codable, Sendable {
    /// One task shares these authoring defaults; per-entry/example values can override them.
    struct Defaults: Codable, Sendable {
        var language: String?
        var meaningLanguage: String?
        var translationLanguage: String?
        var sourceKind: String?
        var status: String?
        var source: String?
    }
    /// A meaning alias carries wording and language while the planner supplies its identity.
    struct Label: Codable, Sendable {
        var text: String
        var language: String?
    }
    /// A local ref either declares a new meaning or binds an existing node without editing it.
    struct Meaning: Codable, Sendable {
        var ref: String
        var id: UUID?
        var title: String?
        var language: String?
        var kind: String?
        var aliases: [Label]?
        var definition: String?
        var cues: [String]?
        var status: String?
        var categories: [String]?
    }
    /// A lexical header groups the distinct senses being saved in this task.
    public struct Entry: Codable, Sendable {
        var expression: String
        var language: String?
        var kind: String?
        var dictionaryForm: String?
        public var senses: [Sense]
    }
    /// A new definition or an exact existing sense receives additive examples and associations.
    public struct Sense: Codable, Sendable {
        var id: UUID?
        var meaning: String?
        var meaningLanguage: String?
        /// The current sense explanation is stored as rich content, independently of examples.
        var explanation: String?
        var note: String?
        var tags: [String]?
        public var examples: [NotebookCaptureExample]?
        var associations: [Association]?
    }
    /// One whole-sense node link retains only genuine applicability conditions and adoption status.
    struct Association: Codable, Sendable {
        var meaning: String
        var conditions: String?
        var status: String?
    }
    /// Local refs describe an explicit node relation, validated with the final graph.
    struct Relation: Codable, Sendable {
        var from: String
        var to: String
        var kind: String
        var note: String?
        var status: String?
    }
    public var referencesExistingRecords: Bool {
        meanings?.contains(where: { $0.id != nil }) == true || entries.contains { $0.senses.contains { $0.id != nil || $0.examples?.contains(where: { $0.sourceID != nil }) == true } }
    }
    var defaults: Defaults?
    var meanings: [Meaning]?
    public var entries: [Entry]
    var relations: [Relation]?
}

public nonisolated struct NotebookCaptureExample: Codable, Sendable {
    public struct Range: Codable, Sendable {
        public var location: Int
        public var length: Int
    }
    public var text: String
    public var translation: String?
    public var translationLanguage: String?
    public var completeness: String?
    public var sourceKind: String?
    /// Reuse an explicit immutable source when adding another translation of its occurrence.
    /// Without this ID, a new capture is distinct even when its sentence text is identical.
    public var sourceID: UUID?
    public var source: String?
    public var ranges: [Range]?
}

/// A revision-bound edit names one accepted example. Omitted fields preserve saved values;
/// changed source text creates new evidence while retaining the example's editor identity.
public nonisolated struct NotebookExampleEdit: Codable, Sendable {
    public var id: UUID
    public var text: String?
    public var translation: String?
    public var translationLanguage: String?
    public var completeness: String?
    public var sourceKind: String?
    public var source: String?
    public var ranges: [NotebookCaptureExample.Range]?
}
