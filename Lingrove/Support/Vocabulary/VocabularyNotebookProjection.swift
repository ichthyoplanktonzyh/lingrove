import Foundation

/// Existing cards and editors consume joined notebook values. This pure adapter is the sole
/// translation between that shape and independently owned catalog, evidence, claims and personal
/// state. It performs no IO, classification or graph construction and is owned by no UI object.
nonisolated enum VocabularyNotebookProjection {
    static func entries(_ document: VocabularyDocument, collectedOnly: Bool) -> [VocabularyEntry] {
        let sources = Dictionary(document.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let occurrences = Dictionary(document.occurrences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let collections = Dictionary(document.collections.map { ($0.senseID, $0) }, uniquingKeysWith: { first, _ in first })
        let claims = Dictionary(grouping: document.interpretations.filter { $0.status == .accepted }, by: \.senseID)
        return document.catalog.compactMap { header in
            var entry = header
            entry.senses = header.senses.compactMap { header in
                let collection = collections[header.id]
                if collectedOnly && collection == nil { return nil }
                let selected = Set(collection?.interpretationIDs ?? [])
                var sense = header
                sense.examples = (claims[header.id] ?? []).compactMap { claim in
                    if collectedOnly && !selected.contains(claim.id) { return nil }
                    guard let occurrence = occurrences[claim.occurrenceID], let source = sources[occurrence.sourceID] else { return nil }
                    return example(claim, occurrence: occurrence, source: source)
                }
                sense.note = collection?.note ?? ""; sense.tags = collection?.tags ?? []
                sense.content = collection?.content; sense.review = collection?.review; sense.reviewCards = collection?.reviewCards
                sense.isSavedWithoutContext = collection?.isSavedWithoutContext ?? false
                return sense
            }
            return collectedOnly && entry.senses.isEmpty ? nil : entry
        }
    }

    static func example(_ claim: VocabularyInterpretation, occurrence: VocabularySourceOccurrence,
                        source: VocabularySourceSnapshot) -> VocabularyExample {
        .init(id: claim.id, sourceID: source.id, occurrenceID: occurrence.id == claim.id ? nil : occurrence.id, sourceKind: source.kind,
            text: source.text, translation: claim.translation, translationLanguage: claim.translationLanguage,
            translationVariants: claim.translationVariants, ranges: occurrence.ranges, completeness: claim.completeness,
            meaning: claim.meaning, meaningLanguage: claim.meaningLanguage, meaningOrigin: claim.meaningOrigin,
            appBundleIdentifier: source.appBundleIdentifier, createdAt: claim.createdAt, explanations: claim.explanations)
    }

    /// This adapter handles explicit lexical edits. Raw sources/occurrences are never inferred
    /// to be garbage merely because the last displayed interpretation was removed. CLI resource
    /// mutations edit canonical records directly and therefore never implicitly collect them.
    static func replace(_ entries: [VocabularyEntry], in document: inout VocabularyDocument) {
        let priorSenseIDs = Set(document.catalog.flatMap(\.senses).map(\.id))
        let priorClaimIDs = Set(document.interpretations.filter { $0.status == .accepted && $0.senseID != nil }.map(\.id))
        let senseIDs = Set(entries.flatMap(\.senses).map(\.id))
        let claimIDs = Set(entries.flatMap(\.examples).map(\.id))
        document.collections.removeAll { !senseIDs.contains($0.senseID) }
        document.interpretations.removeAll { priorClaimIDs.contains($0.id) && !claimIDs.contains($0.id) }
        // Unresolved candidates survive a deleted lexical destination. They retain their claim
        // identity and evidence and can be assigned another destination in a later transaction.
        for index in document.interpretations.indices {
            if let senseID = document.interpretations[index].senseID, !senseIDs.contains(senseID) {
                document.interpretations[index].senseID = nil
                document.interpretations[index].status = .candidate
            }
        }
        document.catalog = entries.map { entry in
            var header = entry
            header.senses = entry.senses.map { sense in
                var header = sense
                header.examples = []; header.note = ""; header.tags = []; header.isSavedWithoutContext = false
                header.content = nil; header.review = nil; header.reviewCards = nil
                return header
            }
            return header
        }
        var offsets = Offsets(document)
        for sense in entries.flatMap(\.senses) {
            let oldCollection = offsets.collections[sense.id].map { document.collections[$0] }
            if oldCollection != nil || !priorSenseIDs.contains(sense.id) {
                var collection = oldCollection ?? .init(senseID: sense.id, savedAt: sense.createdAt)
                collection.note = sense.note; collection.tags = sense.tags; collection.content = sense.content
                collection.review = sense.review; collection.reviewCards = sense.reviewCards
                collection.isSavedWithoutContext = sense.isSavedWithoutContext
                let selected = Set(collection.interpretationIDs)
                collection.interpretationIDs = sense.examples.filter {
                    selected.contains($0.id) || !priorClaimIDs.contains($0.id)
                }.map(\.id)
                upsert(collection, in: &document.collections, offsets: &offsets.collections, id: \.senseID)
            }
            for example in sense.examples { retain(example, senseID: sense.id, in: &document, offsets: &offsets) }
        }
    }

    /// One reconciliation indexes each table once. A word-list import can contain thousands
    /// of examples; repeated full-array identity scans would make a pure adapter quadratic.
    private struct Offsets {
        var sources: [UUID: Int]
        var occurrences: [UUID: Int]
        var claims: [UUID: Int]
        var collections: [UUID: Int]
        init(_ document: VocabularyDocument) {
            sources = Self.index(document.sources.map(\.id)); occurrences = Self.index(document.occurrences.map(\.id))
            claims = Self.index(document.interpretations.map(\.id)); collections = Self.index(document.collections.map(\.senseID))
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
            if source.text != example.text || source.kind != example.sourceKind ||
                source.appBundleIdentifier != example.appBundleIdentifier {
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

    static func collect(senseID: UUID, interpretationID: UUID?, withoutContext: Bool = false,
                        in document: inout VocabularyDocument, now: Date) {
        var value = document.collections.first { $0.senseID == senseID } ?? .init(senseID: senseID, savedAt: now)
        if let interpretationID, !value.interpretationIDs.contains(interpretationID) { value.interpretationIDs.append(interpretationID) }
        value.isSavedWithoutContext = value.isSavedWithoutContext || withoutContext
        upsert(value, in: &document.collections, id: \.senseID)
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
