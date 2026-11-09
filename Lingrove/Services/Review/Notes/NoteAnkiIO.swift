import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The app's Anki controller owns this worker. It borrows the same database/media paths as
/// built-in review, but stores device/profile-specific remote receipts in an adjacent journal.
/// Every read/write checks the captured notebook scope; no network operation runs in SQLite.
actor NoteAnkiIO {
    let databaseURL: URL
    let mediaURL: URL
    private let journalURL: URL
    init(repository: MacNotebookRepository) {
        databaseURL = repository.databaseURL
        mediaURL = repository.mediaDirectoryURL
        journalURL = repository.databaseURL.appendingPathExtension("anki-notes.json")
    }
    struct Material: Sendable {
        let note: ReviewNote
        let type: ReviewNoteType
        let scope: LingroveNotebookSnapshot
        let entry: VocabularyEntry
        let sense: VocabularySense
        let export: ReviewNoteAnkiExport
        var referencedImages: [VocabularyImageReference] {
            let html =
                export.fields.values.joined(separator: "\n") + type.css
                + type.templates.map { $0.front + $0.back }.joined()
            return VocabularyContentPolicy.images(sense.content ?? []).filter { html.contains($0.filename) }
        }
    }
    func types(scope: LingroveNotebookSnapshot) throws -> ([ReviewNoteType], ReviewNoteType) {
        try engine { (try $0.reviewNoteTypes(scope: scope), try $0.defaultReviewNoteType(scope: scope)) }
    }
    func material(
        selection: VocabularySelection, type: ReviewNoteType, scope: LingroveNotebookSnapshot,
        preparing: Bool = false
    ) throws -> Material {
        try engine { engine in
            guard try engine.reviewNoteTypes(scope: scope).contains(type),
                let entry = scope.document.entries.first(where: { $0.id == selection.entryID }),
                let sense = entry.senses.first(where: { $0.id == selection.senseID })
            else { throw VocabularyError.editConflict }
            let note =
                try preparing
                ? engine.prepareReviewNote(selection: selection, type: type, scope: scope)
                : engine.previewReviewNote(selection: selection, type: type, scope: scope)
            var resolved = note
            resolved.entryID = entry.id
            return .init(
                note: note, type: type, scope: scope, entry: entry, sense: sense,
                export: try .init(note: resolved, type: type, entry: entry, sense: sense))
        }
    }
    func validate(_ material: Material) throws {
        let latest = try self.material(
            selection: .init(entryID: material.entry.id, senseID: material.sense.id),
            type: material.type, scope: material.scope)
        guard latest.note == material.note else { throw VocabularyError.editConflict }
    }
    func image(_ reference: VocabularyImageReference, material: Material) throws -> Data {
        try validate(material)
        return try engine {
            try LingroveNotebookMediaStore(core: $0.core).image(
                reference, scope: material.scope, requireActiveWorkspace: true)
        }
    }
    func journal() throws -> NoteAnkiJournal {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return .init() }
        return try JSONDecoder().decode(NoteAnkiJournal.self, from: Data(contentsOf: journalURL))
    }
    func save(_ value: NoteAnkiJournal, material: Material) throws {
        try validate(material)
        let data = try JSONEncoder().encode(value)
        try data.write(to: journalURL, options: .atomic)
    }
    private func engine<T>(_ body: (LingroveNotebookEngine) throws -> T) throws -> T {
        try Task.checkCancellation()
        let value = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaURL)
        defer { try? value.close() }
        return try body(value)
    }
}
