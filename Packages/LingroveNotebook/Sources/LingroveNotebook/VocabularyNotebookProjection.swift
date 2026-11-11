import Foundation

/// Joins saved senses to their accepted interpretations and source evidence for notebook
/// readers. Editors write through the same boundary so corrected text keeps independent evidence.
public nonisolated enum VocabularyNotebookProjection {
    public static func entries(_ document: VocabularyDocument) -> [VocabularyEntry] {
        entries(document.catalog, in: document)
    }

    public static func entry(_ id: UUID, in document: VocabularyDocument) -> VocabularyEntry? {
        guard let entry = document.catalog.first(where: { $0.id == id }) else { return nil }
        // A single-entry caller needs only its own accepted claims and the evidence they name.
        // Scanning canonical arrays avoids building three dictionaries for the entire notebook.
        let senseIDs = Set(entry.senses.map(\.id))
        let claims = document.interpretations.filter { $0.status == .accepted && $0.senseID.map(senseIDs.contains) == true }
        let occurrenceIDs = Set(claims.map(\.occurrenceID))
        let occurrences = Dictionary(document.occurrences.lazy.filter { occurrenceIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let sourceIDs = Set(occurrences.values.map(\.sourceID))
        let sources = Dictionary(document.sources.lazy.filter { sourceIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return joined(entry, claims: Dictionary(grouping: claims, by: \.senseID), occurrences: occurrences, sources: sources)
    }

    private static func entries(_ catalog: [VocabularyEntry], in document: VocabularyDocument) -> [VocabularyEntry] {
        let sources = Dictionary(document.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let occurrences = Dictionary(document.occurrences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let claims = Dictionary(grouping: document.interpretations.filter { $0.status == .accepted }, by: \.senseID)
        return catalog.map { joined($0, claims: claims, occurrences: occurrences, sources: sources) }
    }

    private static func joined(_ header: VocabularyEntry, claims: [UUID?: [VocabularyInterpretation]],
                               occurrences: [UUID: VocabularySourceOccurrence], sources: [UUID: VocabularySourceSnapshot])
        -> VocabularyEntry {
        var entry = header
        entry.senses = header.senses.map { header in
            var sense = header
            sense.examples = (claims[header.id] ?? []).compactMap { claim in
                guard let occurrence = occurrences[claim.occurrenceID], let source = sources[occurrence.sourceID] else { return nil }
                return example(claim, occurrence: occurrence, source: source)
            }
            return sense
        }
        return entry
    }

    public static func example(_ claim: VocabularyInterpretation, occurrence: VocabularySourceOccurrence,
                        source: VocabularySourceSnapshot) -> VocabularyExample {
        .init(id: claim.id, sourceID: source.id, occurrenceID: occurrence.id == claim.id ? nil : occurrence.id, sourceKind: source.kind,
            text: source.text, translation: claim.translation, translationLanguage: claim.translationLanguage,
            translationVariants: claim.translationVariants, ranges: occurrence.ranges, completeness: claim.completeness,
            meaning: claim.meaning, meaningLanguage: claim.meaningLanguage, meaningOrigin: claim.meaningOrigin,
            appBundleIdentifier: source.appBundleIdentifier, createdAt: claim.createdAt, explanations: claim.explanations)
    }

    /// Deleting a use removes the accepted interpretation. The original evidence can still
    /// be cited by another interpretation or associated source record.
    public static func replace(_ entries: [VocabularyEntry], in document: inout VocabularyDocument) {
        let priorClaimIDs = Set(document.interpretations.filter { $0.status == .accepted && $0.senseID != nil }.map(\.id))
        let senseIDs = Set(entries.flatMap(\.senses).map(\.id))
        let claimIDs = Set(entries.flatMap(\.examples).map(\.id))
        document.interpretations.removeAll { priorClaimIDs.contains($0.id) && !claimIDs.contains($0.id) }
        // Unresolved candidates survive a deleted lexical destination. They retain their claim
        // identity and evidence and can be assigned another destination in a later transaction.
        for index in document.interpretations.indices {
            if let senseID = document.interpretations[index].senseID, !senseIDs.contains(senseID) {
                document.interpretations[index].senseID = nil
                document.interpretations[index].status = .candidate
            }
        }
        document.catalog = entries.map(header)
        var offsets = EntryLookup(document)
        for sense in entries.flatMap(\.senses) {
            for example in sense.examples { retain(example, senseID: sense.id, in: &document, offsets: &offsets) }
        }
    }

    /// A save command replaces one lexical subtree. Unrelated entries and interpretations
    /// are never projected back through an editor, so their literal bytes and ownership survive.
    /// Sources and occurrences are immutable evidence: retain can only reuse them or append new
    /// identities. The validated entry-save boundary checks all resulting relationships.
    static func replaceEntry(_ entry: VocabularyEntry, in document: inout VocabularyDocument, offsets: inout EntryLookup) {
        let previous = document.catalog.first { $0.id == entry.id }
        let oldSenses = Set(previous?.senses.map(\.id) ?? [])
        let senses = Set(entry.senses.map(\.id)), incoming = Set(entry.examples.map(\.id))
        let oldClaims = offsets.claimIDs(senses: oldSenses)
        let removed = Set(oldClaims.filter { id in
            offsets.claim(id, in: document)?.status == .accepted && !incoming.contains(id)
        })
        if !removed.isEmpty {
            document.interpretations.removeAll { removed.contains($0.id) }
            offsets.reindexClaims(document.interpretations)
        }
        for id in offsets.claimIDs(senses: oldSenses.subtracting(senses)) {
            guard let index = offsets.claims[id] else { continue }
            document.interpretations[index].senseID = nil
            document.interpretations[index].status = .candidate
        }
        // Rebuild ownership only for retired-sense candidates; ordinary edits share all maps.
        if !oldSenses.isSubset(of: senses) { offsets.reindexClaims(document.interpretations) }
        upsert(header(entry), in: &document.catalog, id: \.id)
        for sense in entry.senses {
            for example in sense.examples {
                retain(example, senseID: sense.id, in: &document, offsets: &offsets, skipUnchanged: true)
            }
        }
    }

    static func entry(_ id: UUID, in document: VocabularyDocument, lookup: EntryLookup) -> VocabularyEntry? {
        guard var entry = document.catalog.first(where: { $0.id == id }) else { return nil }
        for index in entry.senses.indices {
            // Reproduce the canonical join's construction sequence for this small subtree.
            // This is no durable ordinal: it keeps annotation-only saves from changing the
            // bounded example material used by search merely because a Set iterated differently.
            let ids = (lookup.claimsBySense[entry.senses[index].id] ?? []).sorted {
                (lookup.claims[$0] ?? Int.max) < (lookup.claims[$1] ?? Int.max)
            }
            entry.senses[index].examples = ids.compactMap { id in
                guard let claim = lookup.claim(id, in: document), claim.status == .accepted,
                      let occurrence = lookup.occurrences[claim.occurrenceID].map({ document.occurrences[$0] }),
                      let source = lookup.sources[occurrence.sourceID].map({ document.sources[$0] }) else { return nil }
                return example(claim, occurrence: occurrence, source: source)
            }
        }
        return entry
    }

    private static func header(_ entry: VocabularyEntry) -> VocabularyEntry {
        var header = entry
        for index in header.senses.indices { header.senses[index].examples = [] }
        return header
    }

    /// One reconciliation indexes each table once. A word-list import can contain thousands
    /// of examples; repeated full-array identity scans would make a pure adapter quadratic.
    struct EntryLookup: Sendable {
        var sources: [UUID: Int]
        var occurrences: [UUID: Int]
        var claims: [UUID: Int]
        var claimsBySense: [UUID: Set<UUID>] = [:]
        init(_ document: VocabularyDocument) {
            sources = Self.index(document.sources.map(\.id)); occurrences = Self.index(document.occurrences.map(\.id))
            claims = Self.index(document.interpretations.map(\.id))
            for value in document.interpretations { if let id = value.senseID { claimsBySense[id, default: []].insert(value.id) } }
        }
        func claim(_ id: UUID, in document: VocabularyDocument) -> VocabularyInterpretation? {
            claims[id].map { document.interpretations[$0] }
        }
        func claimIDs(senses: Set<UUID>) -> Set<UUID> {
            senses.reduce(into: Set<UUID>()) { $0.formUnion(claimsBySense[$1] ?? []) }
        }
        mutating func reindexClaims(_ values: [VocabularyInterpretation]) {
            claims = Self.index(values.map(\.id)); claimsBySense = [:]
            for value in values { if let id = value.senseID { claimsBySense[id, default: []].insert(value.id) } }
        }
        private static func index(_ ids: [UUID]) -> [UUID: Int] {
            Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private static func retain(_ input: VocabularyExample, senseID: UUID, in document: inout VocabularyDocument,
                               offsets: inout EntryLookup, skipUnchanged: Bool = false) {
        var example = input
        if let offset = offsets.sources[example.sourceID] {
            let source = document.sources[offset]
            if !source.text.utf8.elementsEqual(example.text.utf8) || source.kind != example.sourceKind ||
                !literal(source.appBundleIdentifier, example.appBundleIdentifier) {
                example.sourceID = UUID()
            }
        }
        var occurrenceID = example.occurrenceID ?? example.id
        if let offset = offsets.occurrences[occurrenceID] {
            let old = document.occurrences[offset]
            if old.sourceID != example.sourceID || old.ranges != example.ranges { occurrenceID = UUID() }
        }
        if offsets.sources[example.sourceID] == nil {
            offsets.sources[example.sourceID] = document.sources.count
            document.sources.append(.init(id: example.sourceID, text: example.text, kind: example.sourceKind,
                appBundleIdentifier: example.appBundleIdentifier, encounteredAt: example.createdAt))
        }
        let occurrence = VocabularySourceOccurrence(id: occurrenceID, sourceID: example.sourceID, ranges: example.ranges)
        if offsets.occurrences[occurrenceID].map({ document.occurrences[$0] != occurrence }) ?? true {
            upsert(occurrence, in: &document.occurrences, offsets: &offsets.occurrences, id: \.id)
        }
        let provenance = offsets.claims[example.id].map { document.interpretations[$0].provenance } ?? .init()
        let claim = VocabularyInterpretation(id: example.id, occurrenceID: occurrenceID, senseID: senseID, status: .accepted,
            meaning: example.meaning, meaningLanguage: example.meaningLanguage, meaningOrigin: example.meaningOrigin,
            translation: example.translation, translationLanguage: example.translationLanguage,
            translationVariants: example.translationVariants, completeness: example.completeness, provenance: provenance,
            explanations: example.explanations, createdAt: example.createdAt)
        let before = offsets.claim(example.id, in: document)
        if before?.senseID != senseID {
            if let old = before?.senseID { offsets.claimsBySense[old]?.remove(claim.id) }
            offsets.claimsBySense[senseID, default: []].insert(claim.id)
        }
        if skipUnchanged, let before, before == claim {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // Only the edited entry's small claims are encoded here. This retains literal
            // Unicode/explanation bytes while avoiding a full claim-array copy for a note edit.
            if let old = try? encoder.encode(before), let new = try? encoder.encode(claim), old == new { return }
        }
        upsert(claim, in: &document.interpretations, offsets: &offsets.claims, id: \.id)
    }

    private static func literal(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.utf8.elementsEqual(rhs.utf8)
        default: false
        }
    }

    private static func upsert<T, ID: Equatable>(_ value: T, in values: inout [T], id: KeyPath<T, ID>) {
        if let index = values.firstIndex(where: { $0[keyPath: id] == value[keyPath: id] }) {
            values[index] = value
        } else { values.append(value) }
    }

    private static func upsert<T, ID: Hashable>(_ value: T, in values: inout [T], offsets: inout [ID: Int], id: KeyPath<T, ID>) {
        if let index = offsets[value[keyPath: id]] { values[index] = value } else {
            offsets[value[keyPath: id]] = values.count; values.append(value)
        }
    }
}
