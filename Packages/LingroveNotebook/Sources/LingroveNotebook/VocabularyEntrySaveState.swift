import Foundation

/// A reusable, fully checked notebook value owned by one SQL connection beside its durable
/// snapshot. Entry writers replace lexical subtrees, while organization writers borrow the
/// unchanged entries to validate their graph. No caller-supplied baseline grants it authority.
/// Full import/restore still uses full document preparation. This value keeps the joined entries
/// and their validated ID sets so editing one entry does not revalidate unrelated explanations,
/// review drafts, or the unchanged classification directory.
public nonisolated struct VocabularyEntrySaveState: Sendable {
    public let document: VocabularyDocument
    public let entries: [VocabularyEntry]
    private let identifiers: [UUID: Set<UUID>]
    private let validationIndex: VocabularyEntryValidationIndex
    private let semanticIndex: VocabularySemanticEntryIndex

    public init(validating document: VocabularyDocument) throws {
        let entries = document.entries
        identifiers = try VocabularyDocumentValidation.validate(document, entries: entries)
        self.document = document; self.entries = entries
        validationIndex = .init(entries: entries, identifiers: identifiers, semantics: document.semantics)
        semanticIndex = .init(document.semantics)
    }

    /// Full import/restore still runs complete preparation. The resulting immutable proof is
    /// handed to SQL and retained after commit, avoiding another full read of identical bytes.
    public init(preparing document: VocabularyDocument, previous: VocabularyDocument, restoringBackup: Bool = false) throws {
        let prepared = try VocabularyDocumentValidation.prepared(document, previous: previous, restoringBackup: restoringBackup)
        self.init(document: prepared.document, entries: prepared.entries, identifiers: prepared.identifiers)
    }

    private init(document: VocabularyDocument, entries: [VocabularyEntry], identifiers: [UUID: Set<UUID>],
                 validationIndex: VocabularyEntryValidationIndex? = nil, semanticIndex: VocabularySemanticEntryIndex? = nil) {
        self.document = document; self.entries = entries; self.identifiers = identifiers
        self.validationIndex = validationIndex ?? .init(entries: entries, identifiers: identifiers, semantics: document.semantics)
        self.semanticIndex = semanticIndex ?? .init(document.semantics)
    }

    /// Organization commands cannot alter lexical evidence. Reuse its checked entries and ID
    /// ownership, then validate the changed graph/directory against that same saved corpus.
    public func editingOrganization(_ edit: VocabularyOrganizationEdit) throws -> VocabularyEntrySaveState {
        try Task.checkCancellation()
        let result = try edit.applying(semantics: document.semantics, classification: document.classification)
        if result.semantics == document.semantics && result.classification == document.classification { return self }
        if result.semantics != document.semantics {
            try VocabularySemanticPolicy.validate(result.semantics, entries: entries)
        }
        // A directory references meaning IDs, not their text. A definition-only semantic
        // edit keeps its existing membership proof, while node changes recheck those links.
        if result.classification != document.classification ||
            result.semantics.nodes.map(\.id) != document.semantics.nodes.map(\.id) {
            try VocabularyClassificationPolicy.validate(result.classification, nodes: result.semantics.nodes)
        }
        try Task.checkCancellation()
        var next = document
        next.semantics = result.semantics
        next.classification = result.classification
        return .init(document: next, entries: entries, identifiers: identifiers,
            validationIndex: result.semantics == document.semantics ? validationIndex : validationIndex.updatingSemantics(result.semantics),
            semanticIndex: result.semantics == document.semantics ? semanticIndex : nil)
    }

    /// The command can change just this saved entry and its examples. It cannot
    /// replace a category, source snapshot, unrelated interpretation, template or semantic node.
    /// Canonical evidence is appended/reused by the projection, then global relationships are
    /// checked once. That is why cached validation of the other entries/directory remains valid.
    public func replacing(_ input: VocabularyEntry) throws -> VocabularyEntrySaveChange {
        try Task.checkCancellation()
        let old = entries.first { $0.id == input.id }
        let oldSenses = Set(old?.senses.map(\.id) ?? [])
        // A reused interpretation ID must already belong to this entry, or be an unresolved
        // candidate. A detached editor cannot steal another entry's accepted interpretation.
        let incomingClaims = Set(input.examples.map(\.id))
        guard !document.interpretations.contains(where: {
            incomingClaims.contains($0.id) && $0.senseID.map { !oldSenses.contains($0) } == true
        }) else { throw VocabularyError.invalidArchive }

        var next = document
        VocabularyNotebookProjection.replaceEntry(VocabularyDocumentValidation.pruningExplanations(input), in: &next)
        guard let entry = VocabularyNotebookProjection.entry(input.id, in: next) else { throw VocabularyError.invalidArchive }
        let ids = try VocabularyDocumentValidation.entryIdentifiers(entry)
        try validationIndex.validate(entry, ids: ids)
        var joined = entries, checkedIDs = identifiers
        if let index = joined.firstIndex(where: { $0.id == entry.id }) { joined[index] = entry } else { joined.append(entry) }
        checkedIDs[entry.id] = ids
        let (semanticIndex, semanticChange) = self.semanticIndex.reconciling(&next.semantics, previous: old, current: entry)
        try Task.checkCancellation()
        // Reconcile changes only patterns/mappings. Nodes, category memberships and the directory
        // were copied from this validated state, so their previous relationship proof still holds.
        let lookup = validationIndex.replacing(old, with: entry, oldIDs: identifiers[entry.id] ?? [], newIDs: ids,
            removedSemanticIDs: semanticChange.removedIdentifiers)
        return .init(previous: document, state: .init(document: next, entries: joined, identifiers: checkedIDs,
            validationIndex: lookup, semanticIndex: semanticIndex), entryID: entry.id, semanticChange: semanticChange)
    }

    /// Removing an existing sense cannot introduce an ID. Reuse the proof for unrelated entries
    /// and recheck the changed graph, including candidates that lost their saved destination.
    public func removingSense(_ senseID: UUID, from entryID: UUID) throws -> VocabularyEntrySaveChange {
        try Task.checkCancellation()
        var next = document
        let joined = try VocabularySenseEditingPolicy.remove(entryID: entryID, senseID: senseID,
            from: &next, previousEntries: entries, reconcilingSemantics: false)
        var checkedIDs = identifiers
        checkedIDs[entryID] = try joined.first { $0.id == entryID }.map(VocabularyDocumentValidation.entryIdentifiers)
        let updated = joined.first { $0.id == entryID }
        let (semanticIndex, semanticChange) = self.semanticIndex.reconciling(&next.semantics,
            previous: entries.first { $0.id == entryID }, current: updated)
        let lookup = validationIndex.replacing(entries.first { $0.id == entryID }, with: updated,
            oldIDs: identifiers[entryID] ?? [], newIDs: checkedIDs[entryID] ?? [],
            removedSemanticIDs: semanticChange.removedIdentifiers)
        return .init(previous: document, state: .init(document: next, entries: joined, identifiers: checkedIDs,
            validationIndex: lookup, semanticIndex: semanticIndex), entryID: entryID, semanticChange: semanticChange)
    }

    public func removingEntry(_ entryID: UUID) throws -> VocabularyEntrySaveChange {
        guard let entry = entries.first(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        var next = self, semanticChange = VocabularySemanticEntryChange.empty
        for sense in entry.senses {
            let change = try next.removingSense(sense.id, from: entryID)
            next = change.state; semanticChange = semanticChange.combining(change.semanticChange)
        }
        return .init(previous: document, state: next, entryID: entryID, semanticChange: semanticChange)
    }
}

/// Only the validated state's narrow command can construct this change. Codec and public-intent
/// adapters use its scope to reuse unchanged roots, rather than accepting arbitrary dirty-ID hints.
/// It is a short-lived preparation value; the SQLite writer owns CAS, media, journal and commit.
public nonisolated struct VocabularyEntrySaveChange: Sendable {
    public let previous: VocabularyDocument
    public let state: VocabularyEntrySaveState
    public let entryID: UUID
    public let semanticChange: VocabularySemanticEntryChange
    public var document: VocabularyDocument { state.document }
    public var affectedSenseIDs: Set<UUID> {
        Set((previous.catalog.first { $0.id == entryID }?.senses.map(\.id) ?? []) +
            (document.catalog.first { $0.id == entryID }?.senses.map(\.id) ?? []))
    }

    /// Review links can still name a historical alias even after its sense has been merged.
    public var affectedReviewSenseIDs: Set<UUID> {
        let before = previous.catalog.first { $0.id == entryID }?.senses ?? []
        let after = document.catalog.first { $0.id == entryID }?.senses ?? []
        return Set((before + after).flatMap { [$0.id] + $0.mergedFrom })
    }

    fileprivate init(previous: VocabularyDocument, state: VocabularyEntrySaveState, entryID: UUID,
                     semanticChange: VocabularySemanticEntryChange) {
        self.previous = previous; self.state = state; self.entryID = entryID
        self.semanticChange = semanticChange
    }
}
