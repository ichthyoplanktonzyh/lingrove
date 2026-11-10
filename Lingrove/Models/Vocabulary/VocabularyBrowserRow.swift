import Foundation
import LingroveNotebook

/// One projected item always represents one native List row. Flattening disclosed senses
/// before rendering lets SwiftUI discover row identity without evaluating every row's View
/// hierarchy; only visible cells need typography, menus and controls.
nonisolated struct VocabularyBrowserRow: Identifiable, Sendable {
    enum Identity: Hashable, Sendable { case entry(UUID), sense(UUID) }
    let entry: VocabularyEntry
    let sense: VocabularySense?
    let senseNumber: Int
    var id: Identity { sense.map { .sense($0.id) } ?? .entry(entry.id) }
}
