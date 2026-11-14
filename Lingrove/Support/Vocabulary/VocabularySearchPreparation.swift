import Foundation
import LingroveNotebook

/// The search actor owns this rebuildable value for one notebook lifetime. Every call compares
/// bounded retrieval inputs, rather than rich entries/source bytes. Normalization and hashing
/// run only for changed destinations; removing this value always permits a complete rebuild.
nonisolated struct VocabularySearchPreparation {
    struct Snapshot: Sendable {
        let documents: [VocabularySearchDocument]
        let meanings: [VocabularyMeaningSearchDocument]
        let embeddingRevision: UUID
        let rebuiltSenses: Set<UUID>
        let rebuiltMeanings: Set<UUID>
    }

    private struct SenseInput: Equatable {
        let selection: VocabularySelection
        let language: LearningLanguage?
        let display: [String]
        let tags: [String]
        let fields: [String]
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.selection == rhs.selection && lhs.language == rhs.language &&
                VocabularySearchPreparation.literal(lhs.display, rhs.display) &&
                VocabularySearchPreparation.literal(lhs.tags, rhs.tags) && VocabularySearchPreparation.literal(lhs.fields, rhs.fields)
        }
    }
    private struct MeaningInput: Equatable {
        let fields: [String]
        let senses: [UUID]
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.senses == rhs.senses && VocabularySearchPreparation.literal(lhs.fields, rhs.fields)
        }
    }
    private struct Title: Equatable {
        let id: UUID
        let text: String
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.text.utf8.elementsEqual(rhs.text.utf8) }
    }
    /// One synchronous preparation pass hands its values/change set to the outer publication
    /// step. Keeping these together avoids mismatching a new array with an old embedding token.
    private struct Batch<Document> {
        let documents: [Document]
        var live: Set<UUID> = []
        let changed: Set<UUID>
        let embeddingChanged: Bool
    }
    private var senseInputs: [UUID: SenseInput] = [:]
    private var meaningInputs: [UUID: MeaningInput] = [:]
    private var documents: [UUID: VocabularySearchDocument] = [:]
    private var meanings: [UUID: VocabularyMeaningSearchDocument] = [:]
    private var titles: [Title] = []
    private var meaningOrder: [UUID] = []
    private var embeddingRevision = UUID()
    private var preparedRevision: UUID?
    private var material: VocabularySearchMaterial?
    private var entrySenses: [UUID: [UUID]] = [:]
    private var documentOffsets: [UUID: Int] = [:]
    private var orderedDocuments: [VocabularySearchDocument] = []
    private var orderedMeanings: [VocabularyMeaningSearchDocument] = []

    mutating func prepare(entries: [VocabularyEntry], semantics: VocabularySemanticIndex,
                          revision: UUID? = nil, entryChange: VocabularySearchEntryChange? = nil) -> Snapshot {
        if let entryChange, let revision, entryChange.revision == revision, entryChange.baseRevision == preparedRevision,
           let delta = prepareEntry(entryChange.entryID, entries: entries) {
            preparedRevision = revision
            return delta
        }
        let material = VocabularySearchMaterial(semantics)
        var normalization = Normalization()
        let senses = prepareSenses(entries, material: material, normalization: &normalization)
        let meanings = prepareMeanings(semantics, material: material, liveSenses: senses.live, normalization: &normalization)
        if senses.embeddingChanged || meanings.embeddingChanged { embeddingRevision = UUID() }
        self.material = material; preparedRevision = revision
        entrySenses = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.senses.map(\.id)) })
        documentOffsets = Dictionary(uniqueKeysWithValues: senses.documents.enumerated().map { ($0.element.id, $0.offset) })
        orderedDocuments = senses.documents; orderedMeanings = meanings.documents
        return .init(documents: senses.documents, meanings: meanings.documents, embeddingRevision: embeddingRevision,
            rebuiltSenses: senses.changed, rebuiltMeanings: meanings.changed)
    }

    /// A proven entry delta reuses semantic material and unaffected document slots. Membership
    /// changes rebuild the lightweight order map; removing a linked meaning destination or a
    /// missing receipt takes the complete semantic path.
    private mutating func prepareEntry(_ id: UUID, entries: [VocabularyEntry]) -> Snapshot? {
        guard let material else { return nil }
        let entry = entries.first { $0.id == id }
        guard entry != nil || entrySenses[id] != nil else { return nil }
        let old = Set(entrySenses[id] ?? []), live = Set(entry?.senses.map(\.id) ?? [])
        let removed = old.subtracting(live)
        // A removed meaning destination changes semantic groups. Those edits need the full
        // semantic pass; unassociated insertions/removals do not invalidate every other field.
        guard removed.isEmpty || orderedMeanings.allSatisfy({ removed.isDisjoint(with: $0.senseIDs) }) else { return nil }
        var changed = Set<UUID>(), embeddingChanged = false
        var normalization = Normalization()
        for sense in entry?.senses ?? [] {
            guard let entry else { continue }
            let fields = material.fields(entry: entry, sense: sense)
            let input = SenseInput(selection: .init(entryID: entry.id, senseID: sense.id), language: entry.language,
                display: [entry.expression, entry.dictionaryForm, sense.displayTitle], tags: sense.tags, fields: fields)
            guard senseInputs[sense.id] != input else { continue }
            let document = VocabularySearchPolicy.document(entry: entry, sense: sense, fields: fields,
                normalizing: { normalization.value($0) })
            embeddingChanged = embeddingChanged || documents[sense.id]?.fingerprint != document.fingerprint
            senseInputs[sense.id] = input; documents[sense.id] = document
            if let offset = documentOffsets[sense.id] { orderedDocuments[offset] = document }
            changed.insert(sense.id)
        }
        for id in removed { documents.removeValue(forKey: id); senseInputs.removeValue(forKey: id) }
        if old != live {
            entrySenses[id] = entry.map { $0.senses.map(\.id) }
            orderedDocuments = entries.flatMap { entry in entry.senses.compactMap { documents[$0.id] } }
            documentOffsets = Dictionary(uniqueKeysWithValues: orderedDocuments.enumerated().map { ($0.element.id, $0.offset) })
            embeddingChanged = true
        }
        if embeddingChanged { embeddingRevision = UUID() }
        return .init(documents: orderedDocuments, meanings: orderedMeanings, embeddingRevision: embeddingRevision,
            rebuiltSenses: changed, rebuiltMeanings: [])
    }

    private mutating func prepareSenses(_ entries: [VocabularyEntry], material: VocabularySearchMaterial,
                                        normalization: inout Normalization)
        -> Batch<VocabularySearchDocument> {
        var liveSenses = Set<UUID>(), changedSenses = Set<UUID>()
        var orderedDocuments: [VocabularySearchDocument] = []
        var embeddingChanged = false
        for entry in entries {
            for sense in entry.senses {
                let fields = material.fields(entry: entry, sense: sense)
                let input = SenseInput(selection: .init(entryID: entry.id, senseID: sense.id), language: entry.language,
                    display: [entry.expression, entry.dictionaryForm, sense.displayTitle], tags: sense.tags, fields: fields)
                liveSenses.insert(sense.id)
                if senseInputs[sense.id] != input {
                    let document = VocabularySearchPolicy.document(entry: entry, sense: sense, fields: fields,
                        normalizing: { normalization.value($0) })
                    embeddingChanged = embeddingChanged || documents[sense.id]?.fingerprint != document.fingerprint
                    senseInputs[sense.id] = input; documents[sense.id] = document; changedSenses.insert(sense.id)
                }
                if let document = documents[sense.id] { orderedDocuments.append(document) }
            }
        }
        let removedSenses = Set(documents.keys).subtracting(liveSenses)
        for id in removedSenses { documents.removeValue(forKey: id); senseInputs.removeValue(forKey: id) }
        embeddingChanged = embeddingChanged || !removedSenses.isEmpty

        return .init(documents: orderedDocuments, live: liveSenses, changed: changedSenses, embeddingChanged: embeddingChanged)
    }

    private mutating func prepareMeanings(
        _ semantics: VocabularySemanticIndex, material: VocabularySearchMaterial, liveSenses: Set<UUID>, normalization: inout Normalization
    ) -> Batch<VocabularyMeaningSearchDocument> {
        var liveMeanings = Set<UUID>(), candidates = Set<UUID>(), nextTitles: [Title] = []
        var changedMeanings = Set<UUID>(), embeddingChanged = false
        for node in semantics.nodes where node.provenance.status == .confirmed {
            var seen = Set<UUID>()
            let senses = (material.sensesByNode[node.id] ?? []).filter { liveSenses.contains($0) && seen.insert($0).inserted }
            guard !senses.isEmpty else { continue }
            candidates.insert(node.id)
            let terms = material.terms(node)
            let input = MeaningInput(fields: terms + [node.definition], senses: senses)
            if meaningInputs[node.id] != input {
                let document = VocabularySearchPolicy.meaningDocument(node: node, senseIDs: senses, terms: terms,
                    normalizing: { normalization.value($0) })
                embeddingChanged = embeddingChanged || meanings[node.id]?.fingerprint != document?.fingerprint
                meanings[node.id] = document; meaningInputs[node.id] = input; changedMeanings.insert(node.id)
            } else if let previous = meanings[node.id] {
                // Role/provenance/display metadata can change without changing vector input.
                // Publish the current authored node while retaining its checked retrieval text.
                meanings[node.id] = .init(node: node, senseIDs: senses, lookupTerms: previous.lookupTerms,
                    text: previous.text, fingerprint: previous.fingerprint, normalizedTerms: previous.normalizedTerms)
            }
            guard meanings[node.id] != nil else { continue }
            liveMeanings.insert(node.id)
            nextTitles.append(.init(id: node.id, text: VocabularyMeaningLabelRules.label(for: node, languages: [])?.text ?? node.title))
        }
        meaningInputs = meaningInputs.filter { candidates.contains($0.key) }
        let removedMeanings = Set(meanings.keys).subtracting(liveMeanings)
        for id in removedMeanings { meanings.removeValue(forKey: id); meaningInputs.removeValue(forKey: id) }
        embeddingChanged = embeddingChanged || !removedMeanings.isEmpty
        if titles != nextTitles {
            titles = nextTitles
            meaningOrder = nextTitles.sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }.map(\.id)
        }
        return .init(documents: meaningOrder.compactMap { meanings[$0] }, changed: changedMeanings, embeddingChanged: embeddingChanged)
    }

    private static func literal(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.elementsEqual(rhs, by: { $0.utf8.elementsEqual($1.utf8) })
    }

    /// Shared labels/headwords recur across senses and meaning destinations. This temporary
    /// memo belongs to one preparation pass; the actor retains only completed documents.
    private struct Normalization {
        private var values: [String: String] = [:]
        mutating func value(_ text: String) -> String {
            if let value = values[text] { return value }
            let value = VocabularySearchPolicy.normalized(text); values[text] = value; return value
        }
    }
}

/// One linear pass groups confirmed associations/cues for both complete and incremental search
/// preparation. Association order and the existing per-sense budgets remain part of retrieval.
nonisolated struct VocabularySearchMaterial {
    private let nodes: [UUID: VocabularyMeaningNode]
    private let nodesBySense: [UUID: [UUID]]
    private let cuesByNode: [UUID: [String]]
    let sensesByNode: [UUID: [UUID]]

    init(_ semantics: VocabularySemanticIndex) {
        nodes = Dictionary(uniqueKeysWithValues: semantics.nodes.filter { $0.provenance.status == .confirmed }.map { ($0.id, $0) })
        let confirmed = semantics.mappings.filter { $0.provenance.status == .confirmed }
        nodesBySense = Dictionary(grouping: confirmed, by: \.senseID).mapValues { $0.map(\.nodeID) }
        sensesByNode = Dictionary(grouping: confirmed, by: \.nodeID).mapValues { $0.map(\.senseID) }
        let cues = Dictionary(uniqueKeysWithValues: semantics.cues.map { ($0.id, $0.text) })
        cuesByNode = Dictionary(grouping: semantics.cueTargets.filter { $0.provenance.status == .confirmed }, by: \.nodeID)
            .mapValues { $0.prefix(12).compactMap { cues[$0.cueID] } }
    }

    func terms(_ node: VocabularyMeaningNode) -> [String] { node.labels.map(\.text) + (cuesByNode[node.id] ?? []) }

    func fields(entry: VocabularyEntry, sense: VocabularySense) -> [String] {
        var result = [entry.expression, entry.dictionaryForm, sense.meaning] +
            sense.standaloneMeanings.map(\.text) + sense.alternateMeanings.map(\.text) + sense.examples.prefix(8).map(\.meaning)
        for id in (nodesBySense[sense.id] ?? []).prefix(8) {
            guard let node = nodes[id] else { continue }
            result += node.labels.map(\.text) + [node.definition] + (cuesByNode[id] ?? [])
        }
        return result
    }
}
