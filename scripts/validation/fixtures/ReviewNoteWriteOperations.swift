import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// A displayed Note/type and its source scope are prepared before timing. Only the public
/// writer is measured; postconditions protect Card identity, scheduling and retained events.
func measureNoteWrite(_ name: String, engine: LingroveNotebookEngine) throws {
    let workspace = try engine.workspaceSettingsStore.loadCloudSettings().activeWorkspaceId!
    let scope = try engine.loadLingroveNotebook(workspaceId: workspace)
    let review = try engine.loadBuiltInNotebookReview(scope: scope, now: Date())
    let customID = identifier(9_500_000)
    let model = review.noteCards.values.first { $0.note.noteTypeID == (name == "note_edit" ? ReviewNoteDefaults.type.id : customID)
        && $0.note.senseID == identifier(2_000_080) }!
    let cards = try engine.cardStore.loadCardsIncludingDeleted(workspaceId: workspace)
    let eventCount = try engine.loadReviewEventCount()
    let start: ContinuousClock.Instant
    if name == "note_edit" {
        var note = model.note
        note.revision += 1
        note.exampleID = scope.document.entries.first { $0.id == note.entryID }!.senses.first { $0.id == note.senseID }!.examples.last!.id
        start = .now
        try engine.saveReviewNote(note, expected: model.note, scope: scope)
    } else {
        var type = ["type_edit_shared", "type_style_shared"].contains(name) ? review.defaultNoteType : model.noteType
        let expected = type
        type.revision += 1
        if name == "type_style_shared" { type.css += "\np{font-size:22px}" }
        else { type.templates[0].back += "<p>Changed template</p>" }
        start = .now
        try engine.saveReviewNoteType(type, expected: expected, scope: scope)
    }
    let duration = start.duration(to: .now).components
    let after = try engine.cardStore.loadCardsIncludingDeleted(workspaceId: workspace)
    precondition(Set(after.map(\.cardId)) == Set(cards.map(\.cardId)))
    let original = Dictionary(uniqueKeysWithValues: cards.map { ($0.cardId, $0) })
    for card in after {
        let prior = original[card.cardId]!
        precondition(card.reps == prior.reps && card.dueAt == prior.dueAt && card.fsrsStability == prior.fsrsStability)
    }
    let retainedEvents = try engine.loadReviewEventCount()
    precondition(retainedEvents == eventCount && eventCount == 1_000)
    print("{\"operation\":\"\(name)\",\"milliseconds\":\(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15),\"cards\":\(cards.count),\"ratings\":\(eventCount)}")
}
