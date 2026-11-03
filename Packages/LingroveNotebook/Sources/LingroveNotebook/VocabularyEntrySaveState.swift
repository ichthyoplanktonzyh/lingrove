import Foundation

/// A reusable, fully checked notebook value for narrow lexical edits. A SQL connection owns one
/// of these alongside its durable snapshot; no caller-supplied baseline grants it authority.
/// Full import/restore still uses full document preparation. This value keeps the joined entries
/// and their validated ID sets so editing one entry does not revalidate unrelated explanations,
/// review drafts, or the unchanged classification directory.
public nonisolated struct VocabularyEntrySaveState: Sendable {
    public let document: VocabularyDocument
    public let entries: [VocabularyEntry]
    private let identifiers: [UUID: Set<UUID>]

    public init(validating document: VocabularyDocument) throws {
        let entries = document.entries
        identifiers = try VocabularyDocumentValidation.validate(document, entries: entries)
        self.document = document; self.entries = entries
    }

    private init(document: VocabularyDocument, entries: [VocabularyEntry], identifiers: [UUID: Set<UUID>]) {
        self.document = document; self.entries = entries; self.identifiers = identifiers
    }

    /// The command can change just this lexical subtree and its personal memberships. It cannot
    /// replace a category, source snapshot, unrelated interpretation, template or semantic node.
    /// Canonical evidence is appended/reused by the projection, then global relationships are
    /// checked once. That is why cached validation of the other entries/directory remains valid.
    public func replacing(_ input: VocabularyEntry, collections: [VocabularyCollectionItem]) throws -> VocabularyEntrySaveChange {
        try Task.checkCancellation()
        let old = entries.first { $0.id == input.id }
        let oldSenses = Set(old?.senses.map(\.id) ?? []), senses = Set(input.senses.map(\.id))
        guard collections.allSatisfy({ senses.contains($0.senseID) }),
              !entries.contains(where: { $0.id != input.id && VocabularyIdentityPolicy.entryKey($0) == VocabularyIdentityPolicy.entryKey(input) }) else {
            throw VocabularyError.invalidArchive
        }
        // A reused interpretation ID must already belong to this entry, or be an unresolved
        // candidate. A detached editor cannot steal another entry's accepted interpretation.
        let otherClaims = Set(document.interpretations.filter {
            $0.senseID.map { !oldSenses.contains($0) } == true
        }.map(\.id))
        guard otherClaims.isDisjoint(with: Set(input.examples.map(\.id))) else { throw VocabularyError.invalidArchive }

        var next = document
        VocabularyNotebookProjection.replaceEntry(VocabularyDocumentValidation.pruningExplanations(input), in: &next)
        let desired = Set(collections.map(\.senseID)), affected = oldSenses.union(senses)
        next.collections.removeAll { affected.contains($0.senseID) && !desired.contains($0.senseID) }
        for collection in collections {
            if let index = next.collections.firstIndex(where: { $0.senseID == collection.senseID }) {
                next.collections[index] = collection
            } else { next.collections.append(collection) }
        }
        guard let entry = VocabularyNotebookProjection.entry(input.id, in: next) else { throw VocabularyError.invalidArchive }
        guard Set(next.collections.map(\.id)).count == next.collections.count else { throw VocabularyError.invalidArchive }
        let ids = try VocabularyDocumentValidation.entryIdentifiers(entry)
        for (id, other) in identifiers where id != entry.id {
            guard ids.isDisjoint(with: other) else { throw VocabularyError.invalidArchive }
        }
        var joined = entries, checkedIDs = identifiers
        if let index = joined.firstIndex(where: { $0.id == entry.id }) { joined[index] = entry } else { joined.append(entry) }
        checkedIDs[entry.id] = ids
        try VocabularyLifecyclePolicy.validate(next)
        VocabularySemanticPolicy.reconcile(&next.semantics, previous: document, previousEntries: entries, entries: joined)
        try VocabularySemanticPolicy.validate(next.semantics, entries: joined)
        try Task.checkCancellation()
        // Reconcile changes only patterns/mappings. Nodes, category memberships and the directory
        // were copied from this validated state, so their previous relationship proof still holds.
        return .init(previous: document, state: .init(document: next, entries: joined, identifiers: checkedIDs), entryID: entry.id)
    }
}

/// Only the validated state's narrow command can construct this change. Codec and public-intent
/// adapters use its scope to reuse unchanged roots, rather than accepting arbitrary dirty-ID hints.
/// It is a short-lived preparation value; the SQLite writer owns CAS, media, journal and commit.
public nonisolated struct VocabularyEntrySaveChange: Sendable {
    public let previous: VocabularyDocument
    public let state: VocabularyEntrySaveState
    public let entryID: UUID
    public var document: VocabularyDocument { state.document }
    public var affectedSenseIDs: Set<UUID> {
        Set((previous.catalog.first { $0.id == entryID }?.senses.map(\.id) ?? []) +
            (document.catalog.first { $0.id == entryID }?.senses.map(\.id) ?? []))
    }

    fileprivate init(previous: VocabularyDocument, state: VocabularyEntrySaveState, entryID: UUID) {
        self.previous = previous; self.state = state; self.entryID = entryID
    }
}
