import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import LingroveNotebookSync

/// Only the serialized writer creates this plan from its checked cache and a validated next
/// state. One value keeps SQL changes, material impact, UI receipts and post-commit cache in
/// agreement. The plan lives for one transaction; failure discards it through Core rollback.
struct LingroveNotebookSavePlan {
    let state: VocabularyEntrySaveState
    let rows: VocabularyEntryRowChange
    let entryIDs: Set<UUID>
    let reviewSenseIDs: Set<UUID>?
    let requiresEntryReload: Bool

    init(previous: LingroveNotebookSaveCache, state: VocabularyEntrySaveState,
         rows: VocabularyEntryRowChange, knownEntryIDs: Set<UUID>? = nil) throws {
        self.state = state; self.rows = rows
        if let knownEntryIDs {
            entryIDs = knownEntryIDs
            reviewSenseIDs = Self.reviewIDs(entries: previous.state.entries, ids: knownEntryIDs)
                .union(Self.reviewIDs(entries: state.entries, ids: knownEntryIDs))
            requiresEntryReload = false
            return
        }
        // Repositioned rows now contain only authored/history/template sequences. Membership
        // rows never compact, so their unchanged survivors need neither receipts nor materials.
        let keys = Set((rows.changed + rows.removed + rows.repositioned).map(\.key))
        let before = try previous.projection.materialRoots(for: keys)
        let after = try rows.projection.materialRoots(for: keys)
        var ids = before.entryIDs.union(after.entryIDs)
        var senses = before.senseIDs.union(after.senseIDs)
        // New evidence is already covered by new claims. Only pre-existing evidence changes
        // can affect other saved interpretations, so ordinary append avoids a second scan.
        if !before.sourceIDs.isEmpty || !before.occurrenceIDs.isEmpty {
            var occurrences = before.occurrenceIDs
            for document in [previous.state.document, state.document] {
                for occurrence in document.occurrences where before.sourceIDs.contains(occurrence.sourceID) {
                    occurrences.insert(occurrence.id)
                }
            }
            for document in [previous.state.document, state.document] {
                for claim in document.interpretations where occurrences.contains(claim.occurrenceID) {
                    if let id = claim.senseID { senses.insert(id) }
                }
            }
        }
        for entry in previous.state.entries + state.entries where entry.senses.contains(where: {
            senses.contains($0.id) || !$0.mergedFrom.allSatisfy { !senses.contains($0) }
        }) { ids.insert(entry.id) }
        entryIDs = ids
        reviewSenseIDs = before.allReviewMaterial || after.allReviewMaterial ? nil :
            Self.reviewIDs(entries: previous.state.entries, ids: ids).union(Self.reviewIDs(entries: state.entries, ids: ids))
        requiresEntryReload = false
    }

    func receipt(from previous: LingroveNotebookSnapshot, to saved: LingroveNotebookSnapshot) -> LingroveNotebookCommittedChange {
        let live = Set(state.entries.map(\.id))
        return .init(base: .init(previous), version: .init(saved),
            updatedEntries: state.entries.filter { entryIDs.contains($0.id) },
            removedEntryIDs: entryIDs.subtracting(live), requiresEntryReload: requiresEntryReload)
    }

    /// Actual persisted roots choose the public comparison scope. Private Anki/audio fields
    /// and bookkeeping timestamps still pass through the established public leaf encoder;
    /// no unmodified corpus/graph is serialized just to classify a batch save.
    func hasPublicChanges(previous: LingroveNotebookSaveCache) throws -> Bool {
        let keys = Set((rows.changed + rows.removed + rows.repositioned).map(\.key))
        let old = try previous.projection.materialRoots(for: keys), new = try rows.projection.materialRoots(for: keys)
        let organization = old.organizationRoots.union(new.organizationRoots)
        var families: [VocabularyPersistenceEntity: Set<UUID>] = [:]
        for key in organization {
            guard let id = UUID(uuidString: key.id) else { throw VocabularyError.invalidArchive }
            families[key.entity, default: []].insert(id)
        }
        let sources = old.sourceIDs.union(new.sourceIDs), occurrences = old.occurrenceIDs.union(new.occurrenceIDs)
        let claims = old.interpretationIDs.union(new.interpretationIDs)
        let templates = old.allReviewMaterial || new.allReviewMaterial ||
            (previous.state.document.reviewTemplates != nil) != (state.document.reviewTemplates != nil)
        func fragment(_ document: VocabularyDocument) -> VocabularyDocument {
            func selected<T: Identifiable>(_ records: [T], _ family: VocabularyPersistenceEntity) -> [T] where T.ID == UUID {
                guard let ids = families[family], !ids.isEmpty else { return [] }
                return records.filter { ids.contains($0.id) }
            }
            let graph = document.semantics, directory = document.classification
            return .init(catalog: entryIDs.isEmpty ? [] : document.catalog.filter { entryIDs.contains($0.id) },
                sources: sources.isEmpty ? [] : document.sources.filter { sources.contains($0.id) },
                occurrences: occurrences.isEmpty ? [] : document.occurrences.filter { occurrences.contains($0.id) },
                interpretations: claims.isEmpty ? [] : document.interpretations.filter { claims.contains($0.id) },
                reviewTemplates: templates ? document.reviewTemplates : nil,
                semantics: .init(nodes: selected(graph.nodes, .meaningNodes), patterns: selected(graph.patterns, .usagePatterns),
                    mappings: selected(graph.mappings, .meaningMappings), relations: selected(graph.relations, .meaningRelations),
                    cues: selected(graph.cues, .retrievalCues), cueTargets: selected(graph.cueTargets, .cueTargets)),
                classification: .init(frameworks: selected(directory.frameworks, .classificationFrameworks),
                    categories: selected(directory.categories, .categories), parents: selected(directory.parents, .categoryParents),
                    memberships: selected(directory.memberships, .categoryMemberships), overrides: selected(directory.overrides, .categoryOverrides)))
        }
        return try VocabularyWirePublicIntent.hasChangesInValidatedFragments(from: fragment(previous.state.document),
            to: fragment(state.document), notebookID: previous.snapshot.notebookId)
    }

    private static func reviewIDs(entries: [VocabularyEntry], ids: Set<UUID>) -> Set<UUID> {
        Set(entries.lazy.filter { ids.contains($0.id) }.flatMap { $0.senses.flatMap { [$0.id] + $0.mergedFrom } })
    }

}
