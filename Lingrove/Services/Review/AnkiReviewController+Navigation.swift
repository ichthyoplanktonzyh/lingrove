import LingroveNotebook
import AppKit
import Foundation

extension AnkiReviewController {
    /// Opening Anki uses its current configured deck. Note exports own model definitions;
    /// navigation never installs templates or rewrites existing remote cards.
    func reviewDeck() async -> String? {
        do {
            let connection = try settings.connection(), deck = settings.deck
            guard try strings(await call("deckNames", [:], connection)).contains(deck),
                  try await call("guiDeckOverview", ["name": .string(deck)], connection) == .bool(true) else {
                throw invalid()
            }
            activateAnki()
            return nil
        } catch { return error.localizedDescription }
    }
}
