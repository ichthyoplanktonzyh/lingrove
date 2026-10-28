import Foundation

/// Resource access is deliberately a pure planner. External agents decide how to organize
/// material; this boundary enforces IDs, immutable evidence, typed fields and explicit links.
/// Catalog writes never create personal collection membership as an incidental side effect.
nonisolated enum VocabularyCLIResources {
    // One branch per typed resource keeps dispatch exhaustive without dynamic SQL or reflection.
    // swiftlint:disable:next cyclomatic_complexity
    static func records(_ resource: String, in document: VocabularyDocument) throws -> [CLIJSON] {
        switch resource {
        case "entries": return try document.catalog.map { try filtered($0, resource: resource) }
        case "senses":
            return try document.catalog.flatMap { entry in
                try entry.senses.map { sense in
                    guard case var .object(fields) = try filtered(sense, resource: resource) else {
                        throw VocabularyError.invalidArchive
                    }
                    fields["entryID"] = .string(entry.id.uuidString); return CLIJSON.object(fields)
                }
            }
        case "sources": return try document.sources.map { try filtered($0, resource: resource) }
        case "occurrences": return try document.occurrences.map { try filtered($0, resource: resource) }
        case "interpretations": return try document.interpretations.map { try filtered($0, resource: resource) }
        case "collections": return try document.collections.map { try filtered($0, resource: resource) }
        case "nodes": return try document.semantics.nodes.map { try filtered($0, resource: resource) }
        case "patterns": return try document.semantics.patterns.map { try filtered($0, resource: resource) }
        case "mappings": return try document.semantics.mappings.map { try filtered($0, resource: resource) }
        case "relations": return try document.semantics.relations.map { try filtered($0, resource: resource) }
        case "cues": return try document.semantics.cues.map { try filtered($0, resource: resource) }
        case "cueTargets": return try document.semantics.cueTargets.map { try filtered($0, resource: resource) }
        default: _ = try CLIResourceContract.shape(resource); return []
        }
    }

    static func identifier(_ value: CLIJSON, resource: String) throws -> UUID {
        guard case let .object(fields) = value,
              case let .string(text) = fields[resource == "collections" ? "senseID" : "id"],
              let id = UUID(uuidString: text) else { throw CLIError.invalid("Resource writes require an explicit UUID.") }
        return id
    }

    // One branch per typed resource keeps dispatch exhaustive without dynamic SQL or reflection.
    // swiftlint:disable:next cyclomatic_complexity
    static func put(_ input: CLIResourcePut, in document: inout VocabularyDocument, now: Date) throws -> UUID {
        let id = try identifier(input.value, resource: input.resource)
        let proposed = VocabularySemanticProvenance(origin: .model, status: .proposed)
        // Required fields are checked against the submitted object only on creation. On update,
        // omitted fields retain their current value; null clears an optional field and arrays replace.
        switch input.resource {
        case "entries":
            let value = try updated(input, values: document.catalog, id: id,
                fallback: VocabularyEntry(id: id, expression: "", dictionaryForm: "", language: nil, kind: .word,
                    senses: [], createdAt: now, updatedAt: now))
            var entry = value
            if entry.dictionaryForm.isEmpty { entry.dictionaryForm = entry.expression }
            upsert(entry, in: &document.catalog)
        case "senses": try putSense(input, id: id, in: &document, now: now)
        case "sources":
            let value = try updated(input, values: document.sources, id: id,
                fallback: VocabularySourceSnapshot(id: id, text: "", kind: .imported, appBundleIdentifier: nil, encounteredAt: now))
            if let old = document.sources.first(where: { $0.id == id }) {
                // Unix seconds have less submicrosecond precision than Foundation's reference
                // epoch. Compare the public representation, retaining the original exact Date;
                // a read/put echo must neither conflict nor rewrite immutable evidence.
                guard try filtered(old, resource: input.resource) == filtered(value, resource: input.resource) else {
                    throw CLIError(code: .conflict,
                        message: "Source snapshots are immutable. Create a new source UUID for a correction.")
                }
                return id
            }
            upsert(value, in: &document.sources)
        case "occurrences":
            let value = try updated(input, values: document.occurrences, id: id,
                fallback: VocabularySourceOccurrence(id: id, sourceID: id, ranges: []))
            if let old = document.occurrences.first(where: { $0.id == id }), old != value {
                throw CLIError(code: .conflict, message: "Occurrences are immutable. Create a new occurrence UUID for a correction.")
            }
            upsert(value, in: &document.occurrences)
        case "interpretations":
            upsert(try updated(input, values: document.interpretations, id: id,
                fallback: VocabularyInterpretation(id: id, occurrenceID: id, meaningOrigin: .ai, provenance: proposed, createdAt: now)),
                in: &document.interpretations)
        case "collections":
            upsert(try updated(input, values: document.collections, id: id,
                fallback: VocabularyCollectionItem(senseID: id, savedAt: now)), in: &document.collections)
        case "nodes":
            upsert(try updated(input, values: document.semantics.nodes, id: id,
                fallback: VocabularyMeaningNode(id: id, labels: [], provenance: proposed, createdAt: now, updatedAt: now)),
                in: &document.semantics.nodes)
        case "patterns":
            upsert(try updated(input, values: document.semantics.patterns, id: id,
                fallback: VocabularyUsagePattern(id: id, senseID: id, template: "", provenance: proposed)),
                in: &document.semantics.patterns)
        case "mappings":
            upsert(try updated(input, values: document.semantics.mappings, id: id,
                fallback: VocabularyMeaningMapping(id: id, nodeID: id, senseID: id, provenance: proposed)),
                in: &document.semantics.mappings)
        case "relations":
            upsert(try updated(input, values: document.semantics.relations, id: id,
                fallback: VocabularyMeaningRelation(id: id, sourceID: id, targetID: id, provenance: proposed)),
                in: &document.semantics.relations)
        case "cues":
            upsert(try updated(input, values: document.semantics.cues, id: id,
                fallback: VocabularyRetrievalCue(id: id, text: "")), in: &document.semantics.cues)
        case "cueTargets":
            upsert(try updated(input, values: document.semantics.cueTargets, id: id,
                fallback: VocabularyCueTarget(id: id, cueID: id, nodeID: id, provenance: proposed)),
                in: &document.semantics.cueTargets)
        default: _ = try CLIResourceContract.shape(input.resource)
        }
        return id
    }

    private static func putSense(_ input: CLIResourcePut, id: UUID, in document: inout VocabularyDocument, now: Date) throws {
        guard case let .object(fields) = input.value else { throw CLIError.invalid("Expected a resource object.") }
        let previous = document.catalog.first { $0.senses.contains { $0.id == id } }
        let parentID: UUID?
        if case let .string(text) = fields["entryID"] { parentID = UUID(uuidString: text) } else { parentID = previous?.id }
        guard let parentID, let parent = document.catalog.firstIndex(where: { $0.id == parentID }) else {
            throw CLIError(code: .notFound, message: "Create the parent entry before writing its sense.")
        }
        let old = previous?.senses.first { $0.id == id }
        let value = try updated(input, values: old.map { [$0] } ?? [], id: id,
            fallback: VocabularySense(id: id, meaning: "", meaningOrigin: .ai, createdAt: now, updatedAt: now,
                createdWithoutContext: true))
        if previous?.id == parentID, let index = document.catalog[parent].senses.firstIndex(where: { $0.id == id }) {
            document.catalog[parent].senses[index] = value
        } else {
            for index in document.catalog.indices { document.catalog[index].senses.removeAll { $0.id == id } }
            document.catalog[parent].senses.append(value)
        }
    }

    // One branch per typed resource keeps dispatch exhaustive without dynamic SQL or reflection.
    // swiftlint:disable:next cyclomatic_complexity
    static func delete(_ input: CLIResourceDelete, in document: inout VocabularyDocument) throws {
        let existing = try records(input.resource, in: document)
        guard try existing.contains(where: { try identifier($0, resource: input.resource) == input.id }) else {
            throw CLIError(code: .notFound, message: "Resource not found.")
        }
        switch input.resource {
        case "entries":
            guard document.catalog.first(where: { $0.id == input.id })?.senses.isEmpty == true else {
                throw CLIError.invalid("Delete or move the entry's senses explicitly first.")
            }
            document.catalog.removeAll { $0.id == input.id }
        case "senses":
            for index in document.catalog.indices { document.catalog[index].senses.removeAll { $0.id == input.id } }
        case "sources": document.sources.removeAll { $0.id == input.id }
        case "occurrences": document.occurrences.removeAll { $0.id == input.id }
        case "interpretations": document.interpretations.removeAll { $0.id == input.id }
        case "collections": document.collections.removeAll { $0.id == input.id }
        case "nodes": document.semantics.nodes.removeAll { $0.id == input.id }
        case "patterns": document.semantics.patterns.removeAll { $0.id == input.id }
        case "mappings": document.semantics.mappings.removeAll { $0.id == input.id }
        case "relations": document.semantics.relations.removeAll { $0.id == input.id }
        case "cues": document.semantics.cues.removeAll { $0.id == input.id }
        case "cueTargets": document.semantics.cueTargets.removeAll { $0.id == input.id }
        default: _ = try CLIResourceContract.shape(input.resource)
        }
    }

    private static func encoded(_ value: some Encodable) throws -> CLIJSON {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        return try JSONDecoder().decode(CLIJSON.self, from: encoder.encode(value))
    }
    private static func filtered(_ value: some Encodable, resource: String) throws -> CLIJSON {
        guard case let .object(fields) = try encoded(value) else { throw VocabularyError.invalidArchive }
        let allowed = try CLIResourceContract.shape(resource).fields
        return .object(fields.filter { allowed[$0.key] != nil })
    }

    private static func updated<T: Codable & Identifiable>(_ input: CLIResourcePut, values: [T], id: UUID, fallback: T) throws -> T
        where T.ID == UUID {
        let old = values.first { $0.id == id }
        let current = old ?? fallback
        let shape = try CLIResourceContract.shape(input.resource)
        guard case let .object(patch) = try shape.normalized(input.value, creating: old == nil),
              case var .object(base) = try CLIJSON.value(current),
              case let .object(wire) = try encoded(current) else { throw CLIError.invalid("Expected a resource object.") }
        for (key, value) in patch {
            // Keep omitted or echoed timestamps in Foundation's exact native epoch. Only an
            // explicitly changed public Unix value needs conversion before domain decoding.
            if case .date? = shape.fields[key] {
                if wire[key] != value { base[key] = try nativeDate(value) }
                continue
            }
            if case let .object(changes) = value, case let .object(prior) = base[key] {
                base[key] = .object(prior.merging(changes) { _, new in new })
            } else { base[key] = value }
        }
        if input.resource == "senses" { base.removeValue(forKey: "entryID") }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: JSONEncoder().encode(CLIJSON.object(base)))
        } catch { throw CLIError.invalid("Resource fields do not match the typed record. Check language codes and required fields.") }
    }

    private static func nativeDate(_ value: CLIJSON) throws -> CLIJSON {
        let seconds: Double
        switch value {
        case let .number(value): seconds = value
        case let .integer(value): seconds = Double(value)
        default: throw CLIError.invalid("Expected a Unix timestamp.")
        }
        return try .value(Date(timeIntervalSince1970: seconds))
    }

    private static func upsert<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
    }
}
