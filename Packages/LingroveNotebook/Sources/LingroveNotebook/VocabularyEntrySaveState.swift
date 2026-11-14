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
    private let projectionLookup: VocabularyNotebookProjection.EntryLookup
    private let mediaIndex: VocabularyMediaReferenceIndex
    public var mediaReferences: Set<VocabularyImageReference> { mediaIndex.references }

    public init(validating document: VocabularyDocument) throws {
        let entries = document.entries
        identifiers = try VocabularyDocumentValidation.validate(document, entries: entries)
        self.document = document; self.entries = entries
        validationIndex = .init(entries: entries, identifiers: identifiers, semantics: document.semantics)
        semanticIndex = .init(document.semantics)
        projectionLookup = .init(document)
        mediaIndex = .init(document)
    }

    /// Full import/restore still runs complete preparation. The resulting immutable proof is
    /// handed to SQL and retained after commit, avoiding another full read of identical bytes.
    public init(preparing document: VocabularyDocument, previous: VocabularyDocument, restoringBackup: Bool = false) throws {
        let prepared = try VocabularyDocumentValidation.prepared(document, previous: previous, restoringBackup: restoringBackup)
        self.init(document: prepared.document, entries: prepared.entries, identifiers: prepared.identifiers)
    }

    public init(preparing document: VocabularyDocument, previous: Self, restoringBackup: Bool = false) throws {
        let prepared = try VocabularyDocumentValidation.prepared(document, previous: previous.document,
            restoringBackup: restoringBackup, previousEntries: previous.entries)
        self.init(document: prepared.document, entries: prepared.entries, identifiers: prepared.identifiers)
    }

    private init(document: VocabularyDocument, entries: [VocabularyEntry], identifiers: [UUID: Set<UUID>],
                 validationIndex: VocabularyEntryValidationIndex? = nil, semanticIndex: VocabularySemanticEntryIndex? = nil,
                 projectionLookup: VocabularyNotebookProjection.EntryLookup? = nil, mediaIndex: VocabularyMediaReferenceIndex? = nil) {
        self.document = document; self.entries = entries; self.identifiers = identifiers
        self.validationIndex = validationIndex ?? .init(entries: entries, identifiers: identifiers, semantics: document.semantics)
        self.semanticIndex = semanticIndex ?? .init(document.semantics)
        self.projectionLookup = projectionLookup ?? .init(document)
        self.mediaIndex = mediaIndex ?? .init(document)
    }

    /// Organization commands cannot alter lexical evidence. Reuse its checked entries and ID
    /// ownership, then validate the changed graph/directory against that same saved corpus.
    public func editingOrganization(_ edit: VocabularyOrganizationEdit) throws -> VocabularyEntrySaveState {
        try changingOrganization(edit).state
    }

    public func changingOrganization(_ edit: VocabularyOrganizationEdit) throws -> VocabularyOrganizationSaveChange {
        try Task.checkCancellation()
        let result = try edit.applying(semantics: document.semantics, classification: document.classification)
        var next = document
        next.semantics = result.semantics; next.classification = result.classification
        let scope = VocabularyOrganizationScope(edit, before: document, after: next)
        if result.semantics == document.semantics && result.classification == document.classification {
            return .init(previous: document, state: self, scope: scope)
        }
        if result.semantics != document.semantics {
            try VocabularySemanticPolicy.validateChange(result.semantics, previous: document.semantics, entries: entries, scope: scope)
        }
        // A directory references meaning IDs, not their text. A definition-only semantic
        // edit keeps its existing membership proof, while node changes recheck those links.
        if result.classification != document.classification ||
            result.semantics.nodes.map(\.id) != document.semantics.nodes.map(\.id) {
            try VocabularyClassificationPolicy.validate(result.classification, nodes: result.semantics.nodes)
        }
        try Task.checkCancellation()
        let oldIDs = VocabularySemanticPolicy.identifiers(scope.semantics(in: document.semantics))
        let newIDs = VocabularySemanticPolicy.identifiers(scope.semantics(in: result.semantics))
        let state = Self(document: next, entries: entries, identifiers: identifiers,
            validationIndex: validationIndex.updatingSemanticIDs(removing: oldIDs.subtracting(newIDs), adding: newIDs.subtracting(oldIDs)),
            semanticIndex: scope.patterns.isEmpty && scope.mappings.isEmpty ? semanticIndex : nil,
            projectionLookup: projectionLookup, mediaIndex: mediaIndex)
        return .init(previous: document, state: state, scope: scope)
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
        guard incomingClaims.allSatisfy({ id in
            projectionLookup.claim(id, in: document)?.senseID.map(oldSenses.contains) ?? true
        }) else { throw VocabularyError.invalidArchive }

        var next = document
        let pruned = VocabularyDocumentValidation.pruningExplanations(input)
        _ = try VocabularyDocumentValidation.entryIdentifiers(pruned)
        var projectionLookup = self.projectionLookup
        VocabularyNotebookProjection.replaceEntry(pruned, in: &next, offsets: &projectionLookup)
        guard let entry = VocabularyNotebookProjection.entry(input.id, in: next, lookup: projectionLookup) else { throw VocabularyError.invalidArchive }
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
            validationIndex: lookup, semanticIndex: semanticIndex, projectionLookup: projectionLookup,
            mediaIndex: mediaIndex.replacing(entry.id, with: entry)),
            entryID: entry.id, semanticChange: semanticChange,
            previousClaims: self.projectionLookup.claimIDs(senses: oldSenses).union(incomingClaims).compactMap { self.projectionLookup.claim($0, in: document) },
            claims: self.projectionLookup.claimIDs(senses: oldSenses).union(incomingClaims).compactMap { projectionLookup.claim($0, in: next) })
    }

    /// A bounded import of new lexical owners shares one mutable preparation. Every member is
    /// checked against earlier members before insertion, so colliding identities/occurrences
    /// still reject the entire batch. Existing-owner edits retain the ordinary reconciliation.
    public func appendingEntries(_ inputs: [VocabularyEntry]) throws -> VocabularyEntryAppendChange {
        let ids = Set(inputs.map(\.id))
        guard !inputs.isEmpty, inputs.count <= 100, ids.count == inputs.count,
              entries.allSatisfy({ !ids.contains($0.id) }) else { throw VocabularyError.invalidContent }
        var next = document, joined = entries, checkedIDs = identifiers
        var lookup = projectionLookup, validation = validationIndex, media = mediaIndex
        var claims: [VocabularyInterpretation] = []
        for input in inputs {
            try Task.checkCancellation()
            let incoming = Set(input.examples.map(\.id))
            guard incoming.allSatisfy({ lookup.claim($0, in: next)?.senseID == nil }) else { throw VocabularyError.invalidArchive }
            let pruned = VocabularyDocumentValidation.pruningExplanations(input)
            _ = try VocabularyDocumentValidation.entryIdentifiers(pruned)
            VocabularyNotebookProjection.replaceEntry(pruned, in: &next, offsets: &lookup)
            guard let entry = VocabularyNotebookProjection.entry(input.id, in: next, lookup: lookup) else { throw VocabularyError.invalidArchive }
            let entryIDs = try VocabularyDocumentValidation.entryIdentifiers(entry)
            try validation.validate(entry, ids: entryIDs)
            validation.insert(entry, ids: entryIDs)
            checkedIDs[entry.id] = entryIDs; joined.append(entry)
            media = media.replacing(entry.id, with: entry)
            claims += incoming.compactMap { lookup.claim($0, in: next) }
        }
        try Task.checkCancellation()
        return .init(previous: document,
            state: .init(document: next, entries: joined, identifiers: checkedIDs, validationIndex: validation,
                semanticIndex: semanticIndex, projectionLookup: lookup, mediaIndex: media),
            claims: claims)
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
        var projectionLookup = self.projectionLookup
        let ids = projectionLookup.claimIDs(senses: Set(entries.first { $0.id == entryID }?.senses.map(\.id) ?? []))
        projectionLookup.reindexClaims(next.interpretations)
        return .init(previous: document, state: .init(document: next, entries: joined, identifiers: checkedIDs,
            validationIndex: lookup, semanticIndex: semanticIndex, projectionLookup: projectionLookup,
            mediaIndex: mediaIndex.replacing(entryID, with: updated)),
            entryID: entryID, semanticChange: semanticChange,
            previousClaims: ids.compactMap { self.projectionLookup.claim($0, in: document) },
            claims: ids.compactMap { projectionLookup.claim($0, in: next) })
    }

    public func removingEntry(_ entryID: UUID) throws -> VocabularyEntrySaveChange {
        guard let entry = entries.first(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        if entry.senses.isEmpty {
            var next = document, checkedIDs = identifiers
            next.catalog.removeAll { $0.id == entryID }; checkedIDs.removeValue(forKey: entryID)
            let lookup = validationIndex.replacing(entry, with: nil, oldIDs: identifiers[entryID] ?? [],
                newIDs: [], removedSemanticIDs: [])
            return .init(previous: document, state: .init(document: next, entries: entries.filter { $0.id != entryID },
                identifiers: checkedIDs, validationIndex: lookup, semanticIndex: semanticIndex,
                projectionLookup: projectionLookup, mediaIndex: mediaIndex.replacing(entryID, with: nil)),
                entryID: entryID, semanticChange: .empty, previousClaims: [], claims: [])
        }
        var next = self, semanticChange = VocabularySemanticEntryChange.empty
        for sense in entry.senses {
            let change = try next.removingSense(sense.id, from: entryID)
            next = change.state; semanticChange = semanticChange.combining(change.semanticChange)
        }
        let ids = projectionLookup.claimIDs(senses: Set(entry.senses.map(\.id)))
        return .init(previous: document, state: next, entryID: entryID, semanticChange: semanticChange,
            previousClaims: ids.compactMap { projectionLookup.claim($0, in: document) },
            claims: ids.compactMap { next.projectionLookup.claim($0, in: next.document) })
    }

    /// This bounded command only removes tag values. Identity, evidence, graph and media
    /// proofs remain valid, so a batch annotation edit need not revalidate every source.
    public func removingTag(_ tag: String, now: Date = Date()) throws -> VocabularyTagRemovalChange {
        guard !tag.isEmpty, tag.utf8.count <= 200, now.timeIntervalSinceReferenceDate.isFinite else {
            throw VocabularyError.invalidContent
        }
        var next = document, joined = entries, changed = Set<UUID>()
        for index in next.catalog.indices {
            try Task.checkCancellation()
            if VocabularySenseEditingPolicy.removeTag(tag, from: &next.catalog[index], now: now) {
                changed.insert(next.catalog[index].id)
            }
        }
        if !changed.isEmpty {
            for index in joined.indices where changed.contains(joined[index].id) {
                _ = VocabularySenseEditingPolicy.removeTag(tag, from: &joined[index], now: now)
            }
        }
        let state = changed.isEmpty ? self : Self(document: next, entries: joined, identifiers: identifiers,
            validationIndex: validationIndex, semanticIndex: semanticIndex, projectionLookup: projectionLookup, mediaIndex: mediaIndex)
        return .init(state: state, entryIDs: changed)
    }
}

/// Only a checked save state can produce this append proof. The row adapter consumes the new
/// lexical suffix and appended evidence once; the SQL writer owns atomicity and CAS as before.
public nonisolated struct VocabularyEntryAppendChange: Sendable {
    public let previous: VocabularyDocument
    public let state: VocabularyEntrySaveState
    public let claims: [VocabularyInterpretation]
    fileprivate init(previous: VocabularyDocument, state: VocabularyEntrySaveState,
                     claims: [VocabularyInterpretation]) {
        self.previous = previous; self.state = state; self.claims = claims
    }
}

/// Sealed proof for a deterministic annotation-only batch, consumed by the row adapter.
public nonisolated struct VocabularyTagRemovalChange: Sendable {
    public let state: VocabularyEntrySaveState
    public let entryIDs: Set<UUID>
    fileprivate init(state: VocabularyEntrySaveState, entryIDs: Set<UUID>) { self.state = state; self.entryIDs = entryIDs }
}

/// Only the validated state's narrow command can construct this change. Codec and public-intent
/// adapters use its scope to reuse unchanged roots, rather than accepting arbitrary dirty-ID hints.
/// It is a short-lived preparation value; the SQLite writer owns CAS, media, journal and commit.
public nonisolated struct VocabularyEntrySaveChange: Sendable {
    public let previous: VocabularyDocument
    public let state: VocabularyEntrySaveState
    public let entryID: UUID
    public let semanticChange: VocabularySemanticEntryChange
    public let previousClaims: [VocabularyInterpretation]
    public let claims: [VocabularyInterpretation]
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
                     semanticChange: VocabularySemanticEntryChange, previousClaims: [VocabularyInterpretation],
                     claims: [VocabularyInterpretation]) {
        self.previous = previous; self.state = state; self.entryID = entryID
        self.semanticChange = semanticChange
        self.previousClaims = previousClaims; self.claims = claims
    }
}
