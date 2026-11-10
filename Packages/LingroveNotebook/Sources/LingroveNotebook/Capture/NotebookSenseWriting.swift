import Foundation

/// Pure, atomic sense editing shared by native hosts. The caller supplies revision and stable
/// operation IDs; failures leave the input document untouched. The surrounding storage service
/// remains responsible for owner/generation fences, media bytes and the final SQL transaction.
public nonisolated enum NotebookSenseWriting {
    public static func update(_ update: NotebookSenseUpdate, in document: inout VocabularyDocument,
                              revision: UInt64, now: Date, id: (String) -> UUID) throws {
        guard let entryIndex = document.catalog.firstIndex(where: { $0.id == update.entryID }),
              let senseIndex = document.catalog[entryIndex].senses.firstIndex(where: { $0.id == update.senseID }) else {
            throw NotebookToolError(code: .notFound, message: "Sense does not belong to this entry.")
        }
        _ = try NotebookSenseUpdate.shape.normalized(.value(update))
        let before = document
        var candidate = document
        var sense = candidate.catalog[entryIndex].senses[senseIndex]
        try applyFields(update, to: &sense, revision: revision, contentID: id("explanation"))
        try VocabularyContentPolicy.validate(sense.content ?? [])
        sense.updatedAt = now
        candidate.catalog[entryIndex].senses[senseIndex] = sense
        candidate.catalog[entryIndex].updatedAt = now
        let entry = candidate.catalog[entryIndex]
        for (position, edit) in (update.exampleEdits ?? []).enumerated() {
            try NotebookExampleWriting.edit(edit, entry: entry, senseID: sense.id, in: &candidate,
                sourceID: id("editedSource." + String(position)), occurrenceID: id("editedOccurrence." + String(position)), now: now)
        }
        try NotebookExampleWriting.remove(update.removeExamples ?? [], senseID: sense.id, from: &candidate)
        try updateLinks(update, senseID: sense.id, document: &candidate, id: id)
        VocabularySemanticPolicy.reconcile(&candidate.semantics, previous: before, entries: candidate.entries)
        document = candidate
    }

    private static func applyFields(
        _ update: NotebookSenseUpdate, to sense: inout VocabularySense, revision: UInt64, contentID: UUID
    ) throws {
        guard update.expectedRevision == revision else {
            throw NotebookToolError(code: .conflict, message: "Notebook revision changed. Read the entry again.")
        }
        guard update.meaning != nil || update.meaningLanguage != nil || update.explanation != nil ||
            update.note != nil || update.tags != nil || !(update.addMeaningVariants ?? []).isEmpty ||
            !(update.contentEdits ?? []).isEmpty || !(update.exampleEdits ?? []).isEmpty || !(update.removeExamples ?? []).isEmpty ||
            !(update.linkNodes ?? []).isEmpty || !(update.unlinkNodes ?? []).isEmpty else {
            throw NotebookToolError.invalid("An update needs at least one field.")
        }
        if let meaning = update.meaning {
            sense.meaning = try NotebookCaptureFields.text(meaning, limit: 32_000, nonempty: true)
            sense.meaningOrigin = .user
        }
        if let code = update.meaningLanguage {
            sense.meaningLanguage = try NotebookCaptureFields.language(code)
            sense.meaningOrigin = .user
        }
        if let variants = update.addMeaningVariants { try NotebookCaptureFields.addMeaningVariants(variants, to: &sense) }
        guard update.explanation == nil || update.contentEdits == nil else {
            throw NotebookToolError.invalid("Choose a plain explanation replacement or contentEdits, not both.")
        }
        if let explanation = update.explanation {
            try VocabularyContentEditingPolicy.replacePlainExplanation(explanation, in: &sense, id: contentID)
        }
        if let edits = update.contentEdits { try VocabularyContentEditingPolicy.apply(edits, to: &sense) }
        if let note = update.note { sense.note = try NotebookCaptureFields.text(note, limit: 262_144) }
        if let values = update.tags { sense.tags = try NotebookCaptureFields.tags(values) }
    }

    private static func updateLinks(_ update: NotebookSenseUpdate, senseID: UUID, document: inout VocabularyDocument, id: (String) -> UUID) throws {
        let removed = Set(update.unlinkNodes ?? [])
        guard removed.allSatisfy({ nodeID in document.semantics.mappings.contains { $0.senseID == senseID && $0.nodeID == nodeID } }) else {
            throw NotebookToolError(code: .notFound, message: "A semantic node is not linked to this sense.")
        }
        document.semantics.mappings.removeAll { $0.senseID == senseID && removed.contains($0.nodeID) }
        for (index, link) in (update.linkNodes ?? []).enumerated() {
            guard let node = document.semantics.nodes.first(where: { $0.id == link.nodeID }) else {
                throw NotebookToolError(code: .notFound, message: "Semantic node not found.")
            }
            let conditions = try NotebookCaptureFields.text(link.conditions ?? "", limit: 8_192)
            if document.semantics.mappings.contains(where: { $0.senseID == senseID && $0.nodeID == node.id &&
                $0.patternID == nil && $0.conditions == conditions }) { continue }
            document.semantics.mappings.append(.init(id: id("link." + String(index)), nodeID: node.id, senseID: senseID,
                relation: node.kind == .concept ? .expressesContent : .realizesFunction, conditions: conditions,
                provenance: .init(origin: .model, status: .confirmed)))
        }
    }

}
