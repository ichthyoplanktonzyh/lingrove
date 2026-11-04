import Foundation

/// A shared note type is a durable definition, not a copied per-card layout. Field and card
/// template IDs survive rename/reordering; renderers use field names only at the template edge.
public nonisolated struct ReviewNoteType: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var revision: UInt64
    public var fields: [ReviewNoteField]
    public var templates: [ReviewCardTemplate]
    public var css: String

    public init(id: UUID = UUID(), name: String, revision: UInt64 = 1, fields: [ReviewNoteField],
                templates: [ReviewCardTemplate], css: String) {
        self.id = id; self.name = name; self.revision = revision
        self.fields = fields; self.templates = templates; self.css = css
    }
}

/// One field either follows a known corpus source or is explicitly owned by its note. Values
/// are portable rich HTML; no platform view, remote URL request or executable field code exists.
public nonisolated struct ReviewNoteField: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case expression, meaning, sentence, translation, notes, richContent, custom
    }
    public var id: UUID
    public var name: String
    public var source: Source
    public init(id: UUID = UUID(), name: String, source: Source) {
        self.id = id; self.name = name; self.source = source
    }
}

/// Front/back HTML belongs to a stable card type. Enabled controls new admission; removing a
/// template never grants permission to erase an existing card's review history.
public nonisolated struct ReviewCardTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var front: String
    public var back: String
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String, front: String, back: String, enabled: Bool = true) {
        self.id = id; self.name = name; self.front = front; self.back = back; self.enabled = enabled
    }
}

/// A source-linked note owns only its bindings and user-defined fields. The current source
/// supplies every generated field at projection time; there is no second editable corpus copy.
public nonisolated struct ReviewNote: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var noteTypeID: UUID
    public var entryID: UUID
    public var senseID: UUID
    public var exampleID: UUID?
    public var customFields: [String: String]
    public var revision: UInt64
    public init(id: UUID = UUID(), noteTypeID: UUID, entryID: UUID, senseID: UUID, exampleID: UUID? = nil,
                customFields: [String: String] = [:], revision: UInt64 = 1) {
        self.id = id; self.noteTypeID = noteTypeID; self.entryID = entryID; self.senseID = senseID
        self.exampleID = exampleID; self.customFields = customFields; self.revision = revision
    }
}

/// Rendering returns an immutable result. The host supplies theme/media resolution and pins
/// this result for a displayed question; it never executes template or field JavaScript.
public nonisolated struct ReviewRenderedCard: Equatable, Sendable {
    public let frontHTML: String
    public let backHTML: String
    public let css: String
    public let fields: [String: String]
    public init(frontHTML: String, backHTML: String, css: String, fields: [String: String]) {
        self.frontHTML = frontHTML; self.backHTML = backHTML; self.css = css; self.fields = fields
    }
}

public nonisolated enum ReviewTemplateError: Error, Equatable, Sendable {
    case invalidDefinition, unknownField(String), unsupportedSyntax(String), unbalancedSection(String), sourceUnavailable
}
