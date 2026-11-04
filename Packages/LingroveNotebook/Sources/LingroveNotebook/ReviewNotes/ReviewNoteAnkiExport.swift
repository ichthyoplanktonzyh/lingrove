import Foundation

/// A target adapter preserves named fields and templates instead of flattening them into
/// Front/Back. Scheduling never crosses this boundary: Anki owns the cards it creates.
public nonisolated struct ReviewNoteAnkiExport: Codable, Equatable, Sendable {
    public let modelName: String
    public let fieldNames: [String]
    public let css: String
    public let templates: [Template]
    public let fields: [String: String]
    public struct Template: Codable, Equatable, Sendable {
        public let name: String
        public let front: String
        public let back: String
    }
    public init(note: ReviewNote, type: ReviewNoteType, entry: VocabularyEntry, sense: VocabularySense) throws {
        try ReviewTemplateRenderer.validate(type)
        guard !type.fields.contains(where: { $0.name == "LingroveNoteID" }) else { throw ReviewTemplateError.invalidDefinition }
        modelName = "Lingrove " + type.id.uuidString.lowercased()
        fieldNames = ["LingroveNoteID"] + type.fields.map(\.name)
        fields = try ReviewNoteProjection.fields(note: note, type: type, entry: entry, sense: sense)
            .merging(["LingroveNoteID": note.id.uuidString.lowercased()]) { old, _ in old }
        css = type.css
        templates = type.templates.filter(\.enabled).map {
            .init(name: $0.id.uuidString.lowercased(), front: $0.front, back: $0.back)
        }
    }
}
