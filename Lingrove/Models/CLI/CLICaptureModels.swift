import Foundation

/// Task-shaped input shared by the executable and app. A capture is a short-lived value owned
/// by one batch: callers describe language material and local meaning references, while the
/// app planner owns durable IDs, evidence, collection membership and graph construction.
nonisolated struct CLICapture: Codable, Sendable {
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
    /// A lexical header groups the distinct senses being collected in this task.
    struct Entry: Codable, Sendable {
        var expression: String
        var language: String?
        var kind: String?
        var dictionaryForm: String?
        var senses: [Sense]
    }
    /// A new definition or an exact existing sense receives additive examples and associations.
    struct Sense: Codable, Sendable {
        var id: UUID?
        var meaning: String?
        var meaningLanguage: String?
        var note: String?
        var tags: [String]?
        var examples: [CLIExample]?
        var associations: [Association]?
    }
    /// One authored meaning link may restrict itself to a concrete usage pattern.
    struct Association: Codable, Sendable {
        var meaning: String
        var usage: String?
        var nuance: String?
        var conditions: String?
        var formality: String?
        var medium: String?
        var collocations: [String]?
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
    var defaults: Defaults?
    var meanings: [Meaning]?
    var entries: [Entry]
    var relations: [Relation]?
}
