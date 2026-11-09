import Foundation

/// Joins saved senses to their accepted interpretations and source evidence for notebook
/// readers. Editors write through the same boundary so corrected text keeps independent evidence.
public nonisolated enum VocabularyNotebookProjection {
    public static func entries(_ document: VocabularyDocument) -> [VocabularyEntry] {
        entries(document.catalog, in: document)
    }

    public static func entry(_ id: UUID, in document: VocabularyDocument) -> VocabularyEntry? {
        guard let entry = document.catalog.first(where: { $0.id == id }) else { return nil }
        return entries([entry], in: document).first
    }

    private static func entries(_ catalog: [VocabularyEntry], in document: VocabularyDocument) -> [VocabularyEntry] {
        let sources = Dictionary(document.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let occurrences = Dictionary(document.occurrences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let claims = Dictionary(grouping: document.interpretations.filter { $0.status == .accepted }, by: \.senseID)
        return catalog.map { header in
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
        var offsets = Offsets(document)
        for sense in entries.flatMap(\.senses) {
            for example in sense.examples { retain(example, senseID: sense.id, in: &document, offsets: &offsets) }
        }
    }

    /// A save command replaces one lexical subtree. Unrelated entries and interpretations
    /// are never projected back through an editor, so their literal bytes and ownership survive.
    /// Sources and occurrences are immutable evidence: retain can only reuse them or append new
    /// identities. The validated entry-save boundary checks all resulting relationships.
    static func replaceEntry(_ entry: VocabularyEntry, in document: inout VocabularyDocument) {
        let previous = document.catalog.first { $0.id == entry.id }
        let oldSenses = Set(previous?.senses.map(\.id) ?? [])
        let senses = Set(entry.senses.map(\.id)), claims = Set(entry.examples.map(\.id))
        document.interpretations.removeAll {
            $0.status == .accepted && $0.senseID.map(oldSenses.contains) == true && !claims.contains($0.id)
        }
        for index in document.interpretations.indices {
            if let id = document.interpretations[index].senseID, oldSenses.contains(id), !senses.contains(id) {
                document.interpretations[index].senseID = nil
                document.interpretations[index].status = .candidate
            }
        }
        upsert(header(entry), in: &document.catalog, id: \.id)
        var offsets = Offsets(document)
        for sense in entry.senses {
            for example in sense.examples { retain(example, senseID: sense.id, in: &document, offsets: &offsets) }
        }
    }

    private static func header(_ entry: VocabularyEntry) -> VocabularyEntry {
        var header = entry
        for index in header.senses.indices { header.senses[index].examples = [] }
        return header
    }

    /// One reconciliation indexes each table once. A word-list import can contain thousands
    /// of examples; repeated full-array identity scans would make a pure adapter quadratic.
    private struct Offsets {
        var sources: [UUID: Int]
        var occurrences: [UUID: Int]
        var claims: [UUID: Int]
        init(_ document: VocabularyDocument) {
            sources = Self.index(document.sources.map(\.id)); occurrences = Self.index(document.occurrences.map(\.id))
            claims = Self.index(document.interpretations.map(\.id))
        }
        private static func index(_ ids: [UUID]) -> [UUID: Int] {
            Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private static func retain(_ input: VocabularyExample, senseID: UUID, in document: inout VocabularyDocument,
                               offsets: inout Offsets) {
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
        upsert(.init(id: occurrenceID, sourceID: example.sourceID, ranges: example.ranges), in: &document.occurrences,
            offsets: &offsets.occurrences, id: \.id)
        let provenance = offsets.claims[example.id].map { document.interpretations[$0].provenance } ?? .init()
        let claim = VocabularyInterpretation(id: example.id, occurrenceID: occurrenceID, senseID: senseID, status: .accepted,
            meaning: example.meaning, meaningLanguage: example.meaningLanguage, meaningOrigin: example.meaningOrigin,
            translation: example.translation, translationLanguage: example.translationLanguage,
            translationVariants: example.translationVariants, completeness: example.completeness, provenance: provenance,
            explanations: example.explanations, createdAt: example.createdAt)
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
