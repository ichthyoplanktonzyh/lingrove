import Foundation
import LingroveNotebook

/// Local Anki receipts belong to a Mac connection/profile, not to the portable corpus. The
/// IO actor writes this journal atomically before remote mutations, retaining enough intent to
/// recover a lost acknowledgement without creating another note or overwriting a customization.
nonisolated struct NoteAnkiJournal: Codable {
    var models: [String: Model] = [:]
    var notes: [String: Note] = [:]
    struct Model: Codable {
        var type: ReviewNoteType?
        var shape: Shape?
        var pending: Plan?
        var templateOrder: [UUID] = []
    }
    struct Shape: Codable, Equatable {
        var fields: [String]
        var order: [String]
        var templates: [String: AnkiValue]
        var css: String
    }
    struct Step: Codable {
        var action: String
        var parameters: [String: AnkiValue]
        var after: Shape
    }
    struct Plan: Codable {
        var type: ReviewNoteType
        var before: Shape?
        var steps: [Step]
    }
    struct Note: Codable {
        var id: Int64?
        var typeID: UUID?
        var localFields: [String: String] = [:]
        var remoteFields: [String: String] = [:]
        var pendingFields: [String: String]?
        var pendingLocalFields: [String: String]?
        var overrides: [String: String] = [:]
        var suspendedCards: Set<Int64> = []
    }
}
