import AppKit
import Foundation

extension AnkiReviewController {
    /// Navigation verifies the saved note's current deck: users may move cards inside Anki.
    /// It opens the deck overview, leaving the actual start/answer/scheduling controls in Anki.
    func reviewDeck(_ binding: AnkiNoteBinding? = nil) async -> String? {
        do {
            let connection = try settings.connection()
            var deck = settings.deck
            if let binding {
                try await verifyScope(binding, connection: connection)
                guard let id = binding.noteID, let note = try await note(id, connection: connection),
                      note.fields[binding.identityField] == binding.originSenseID.uuidString.lowercased() else { throw invalid() }
                let ids = try await call("findCards", ["query": .string("nid:\(id)")], connection)
                guard let cards = ids.array, !cards.isEmpty else { throw invalid() }
                let info = try await call("cardsInfo", ["cards": .array(cards)], connection)
                guard let currentDeck = info.array?.first?.object?["deckName"]?.string else { throw invalid() }
                deck = currentDeck
                try await verifyScope(binding, connection: connection)
            }
            guard try strings(await call("deckNames", [:], connection)).contains(deck),
                  try await call("guiDeckOverview", ["name": .string(deck)], connection) == .bool(true) else {
                throw AnkiReviewError.message(String(localized: "Choose a deck and an Anki association.", table: "Vocabulary"))
            }
            // AnkiConnect navigates inside Anki; activating its existing application is a separate
            // OS concern. Never launch another Anki instance with a different collection here.
            activateAnki()
            return nil
        } catch { return error.localizedDescription }
    }

    /// Only our unchanged legacy/current templates can be upgraded. Fields are appended and
    /// the two template identities stay in place, preserving every existing card and schedule.
    /// User-customized templates are left to Anki instead of being overwritten by an app update.
    func updatePresetTemplate() async throws {
        guard sendingSenseID == nil, !updatingTemplate else { throw VocabularyError.editConflict }
        updatingTemplate = true; defer { updatingTemplate = false }
        let connection = try settings.connection()
        let profile = try await profile(connection)
        let fields = try await fields(for: AnkiReviewPolicy.presetName, connection: connection, create: true)
        let templates = try await call("modelTemplates", ["modelName": .string(AnkiReviewPolicy.presetName)], connection)
        guard templates == .object(AnkiNoteTemplate.legacyTemplates) || templates == .object(AnkiNoteTemplate.templates) else {
            throw AnkiReviewError.message(String(localized: "This template was customized. Manage it in Anki.", table: "Vocabulary"))
        }
        for field in ReviewField.allCases where !fields.contains(field.rawValue) {
            guard try await self.profile(connection) == profile else { throw VocabularyError.editConflict }
            _ = try await call("modelFieldAdd", ["modelName": .string(AnkiReviewPolicy.presetName),
                "fieldName": .string(field.rawValue)], connection)
        }
        guard try await self.profile(connection) == profile else { throw VocabularyError.editConflict }
        _ = try await call("updateModelTemplates", ["model": .object(["name": .string(AnkiReviewPolicy.presetName),
            "templates": .object(AnkiNoteTemplate.templates)])], connection)
        let style = try await call("modelStyling", ["modelName": .string(AnkiReviewPolicy.presetName)], connection)
        if style.object?["css"]?.string == AnkiNoteTemplate.legacyCSS {
            guard try await self.profile(connection) == profile else { throw VocabularyError.editConflict }
            _ = try await call("updateModelStyling", ["model": .object(["name": .string(AnkiReviewPolicy.presetName),
                "css": .string(AnkiNoteTemplate.css)])], connection)
        }
        guard try await self.profile(connection) == profile,
              try await call("modelTemplates", ["modelName": .string(AnkiReviewPolicy.presetName)], connection)
                == .object(AnkiNoteTemplate.templates) else { throw invalid() }
        await refreshFields()
    }
}
