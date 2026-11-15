import Foundation
import LingroveNotebook

/// Persist only retrieval fields/joins, never a document or image bytes. The engine verifies
/// the payload checksum, shape and exact SQL fence before creating a disposable material.
/// ASCII folding is reconstructed from source text so codec changes cannot alter matching.
struct NotebookSearchProjection: Codable {
    let fence: NotebookBrowseFence
    let texts: [String]
    let headers: [NotebookEntrySummary]
    let dates: [UUID: Double]
    let fields: [UUID: [Int]]
    let nodes: [UUID: [Int]]
    let mappings: [NotebookLiteralSearchMaterial.Mapping]
    let cues: [NotebookLiteralSearchMaterial.Link]
    let patterns: [NotebookLiteralSearchMaterial.Link]

    init(_ material: NotebookLiteralSearchMaterial) {
        fence = material.fence
        texts = material.texts.fields.map(\.text); headers = material.headers; dates = material.entryDates
        fields = material.fields; nodes = material.nodes; mappings = material.mappings
        cues = material.cues; patterns = material.patterns
    }
    init(fence: NotebookBrowseFence, texts: [String], headers: [NotebookEntrySummary], dates: [UUID: Double],
         fields: [UUID: [Int]], nodes: [UUID: [Int]], mappings: [NotebookLiteralSearchMaterial.Mapping],
         cues: [NotebookLiteralSearchMaterial.Link], patterns: [NotebookLiteralSearchMaterial.Link]) {
        self.fence = fence; self.texts = texts; self.headers = headers; self.dates = dates
        self.fields = fields; self.nodes = nodes; self.mappings = mappings; self.cues = cues; self.patterns = patterns
    }
    func material(fence: NotebookBrowseFence, locale: String) -> NotebookLiteralSearchMaterial? {
        let entryIDs = Set(headers.map(\.id)), senseIDs = headers.flatMap { $0.senses.map(\.id) }
        guard self.fence == fence, entryIDs.count == headers.count, Set(dates.keys) == entryIDs,
              Set(senseIDs).count == senseIDs.count, Set(fields.keys) == Set(senseIDs),
              dates.values.allSatisfy(\.isFinite) else { return nil }
        let references = fields.values.flatMap { $0 } + nodes.values.flatMap { $0 }
            + mappings.map(\.text) + cues.map(\.text) + patterns.map(\.text)
        guard references.allSatisfy({ texts.indices.contains($0) }) else { return nil }
        return .init(entryDates: dates, texts: .init(fields: texts.map(NotebookSearchTextTable.Field.init)),
            headers: headers, fields: fields, nodes: nodes, mappings: mappings, cues: cues,
            patterns: patterns, fence: fence, locale: locale)
    }
}

extension NotebookLiteralSearchMaterial {
    func localized(_ locale: String) -> Self {
        .init(preparation: preparation, entryDates: entryDates, texts: texts, headers: headers, fields: fields,
            nodes: nodes, mappings: mappings, cues: cues, patterns: patterns, fence: fence, locale: locale)
    }

    /// A certified local entry edit leaves semantic rows and all other owners unchanged.
    /// The persisted base/final clock chain is checked by the engine, not by the UI.
    func applying(_ edit: NotebookSearchCache.EntryEdit) -> Self? {
        applying([edit])
    }

    /// Replay a verified chain with one field builder and final ordering pass. Each frame
    /// still checks ownership against its own starting state; only derived work is shared.
    func applying(_ edits: [NotebookSearchCache.EntryEdit]) -> Self? {
        guard !edits.isEmpty, edits.count <= NotebookSearchCache.maximumJournalFrames else { return nil }
        var oldHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.id,$0) })
        var ownersBySense = Dictionary(uniqueKeysWithValues: headers.flatMap { entry in entry.senses.map { ($0.id,entry.id) } })
        var fields = fields, dates = entryDates, cursor = fence
        var changed = Set<UUID>()
        var liveSenses = Set(ownersBySense.keys)
        var builder = NotebookSearchTextTable.Builder(texts)
        for edit in edits {
            guard !Task.isCancelled, edit.base == cursor, edit.owners.count <= 100,
                  Set(edit.owners.map(\.entryID)).count == edit.owners.count else { return nil }
            var priorOwners: [UUID: UUID] = [:]
            for owner in edit.owners {
                guard !Task.isCancelled else { return nil }
                let oldIDs = Set(oldHeaders[owner.entryID]?.senses.map(\.id) ?? [])
                guard owner.entry?.id == owner.entryID || owner.entry == nil,
                      oldIDs.isSubset(of: owner.previousSenseIDs),
                      owner.previousSenseIDs.allSatisfy({ ownersBySense[$0] == nil || ownersBySense[$0] == owner.entryID }),
                      (owner.entry?.senses ?? []).allSatisfy({ ownersBySense[$0.id] == nil || oldIDs.contains($0.id) }),
                      owner.entry?.createdAt.timeIntervalSinceReferenceDate.isFinite != false else { return nil }
                for id in owner.previousSenseIDs {
                    guard priorOwners[id] == nil || priorOwners[id] == owner.entryID else { return nil }
                    priorOwners[id] = owner.entryID
                }
            }
            for owner in edit.owners {
                guard (owner.entry?.senses ?? []).allSatisfy({ priorOwners[$0.id] == nil || priorOwners[$0.id] == owner.entryID }) else { return nil }
                for id in owner.previousSenseIDs {
                    fields.removeValue(forKey: id); liveSenses.remove(id); ownersBySense.removeValue(forKey: id)
                }
            }
            for owner in edit.owners {
                changed.insert(owner.entryID)
                if let entry = owner.entry {
                    for sense in entry.senses {
                        guard liveSenses.insert(sense.id).inserted, sense.createdAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
                        ownersBySense[sense.id] = entry.id
                    }
                    let summary = NotebookEntrySummary(id: entry.id, expression: entry.expression, language: entry.language,
                        senses: entry.senses.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }.map { sense in
                            let body = (sense.content ?? []).compactMap { block -> String? in
                                if case .text(let value) = block.content { return value.text }; return nil
                            }.first ?? ""
                            return .init(id: sense.id, title: sense.meaning.isEmpty ? body : sense.meaning,
                                hasImage: sense.meaning.isEmpty && !VocabularyContentPolicy.images(sense.content ?? []).isEmpty)
                        })
                    for sense in entry.senses {
                        var values = [entry.expression, entry.dictionaryForm, summary.senses.first { $0.id == sense.id }?.title ?? ""]
                        var additional = [sense.meaning, sense.note] + sense.tags
                            + sense.standaloneMeanings.map(\.text) + sense.alternateMeanings.map(\.text)
                        additional += (sense.content ?? []).map { block in
                            switch block.content { case .text(let value): value.text; case .image(_, let caption): caption }
                        }
                        additional += sense.explanations.flatMap { [$0.result.meaning, $0.result.explanation] }
                        for example in sense.examples {
                            additional += [example.text, example.translation, example.meaning] + example.translationVariants.map(\.text)
                            additional += example.explanations.flatMap { [$0.result.meaning, $0.result.explanation] }
                        }
                        values += additional.filter { !$0.isEmpty }
                        fields[sense.id] = values.map { builder.intern($0) }
                    }
                    oldHeaders[entry.id] = summary
                    dates[entry.id] = entry.createdAt.timeIntervalSinceReferenceDate
                } else {
                    oldHeaders.removeValue(forKey: owner.entryID)
                    dates.removeValue(forKey: owner.entryID)
                }
            }
            cursor = edit.fence
        }
        // Retain the large already-ordered run; only the small changed suffix needs merging.
        var ordered = headers.filter { !changed.contains($0.id) }
        ordered.append(contentsOf: changed.compactMap { oldHeaders[$0] })
        ordered.sort { dates[$0.id] == dates[$1.id] ? $0.id.uuidString < $1.id.uuidString : (dates[$0.id] ?? 0) > (dates[$1.id] ?? 0) }
        return .init(preparation: .incremental, entryDates: dates, texts: builder.finish(), headers: ordered,
            fields: fields, nodes: nodes, mappings: mappings, cues: cues, patterns: patterns,
            fence: cursor, locale: locale)
    }
}
