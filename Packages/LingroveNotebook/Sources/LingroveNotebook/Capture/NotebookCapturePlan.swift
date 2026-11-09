import Foundation

/// The archive creates this pure, transaction-scoped planner from one immutable baseline.
/// It hides canonical evidence joins behind language material and local references.
/// Deterministic IDs come from the enclosing batch, so preview, commit and retries agree;
/// no model, database handle or UI object is created here.
public nonisolated struct NotebookCapturePlan {
    public private(set) var document: VocabularyDocument
    public private(set) var entries: [NotebookToolJSON] = []
    public private(set) var meanings: [NotebookToolJSON] = []
    private var nodes: [String: UUID] = [:]
    private let defaults: NotebookCaptureTask.Defaults
    private let now: Date
    private let id: (String) -> UUID
    private var mappingCount = 0
    private var exampleCount = 0
    private var senseCount = 0
    private var categoryMembershipCount = 0

    public var summary: NotebookToolJSON {
        .object(["entryCount": .integer(Int64(entries.count)), "senseCount": .integer(Int64(senseCount)),
            "exampleCount": .integer(Int64(exampleCount)), "meaningCount": .integer(Int64(meanings.count)),
            "associationCount": .integer(Int64(mappingCount)),
            "categoryMembershipCount": .integer(Int64(categoryMembershipCount))])
    }

    public init(_ capture: NotebookCaptureTask, document: VocabularyDocument, now: Date, id: @escaping (String) -> UUID) throws {
        try NotebookCaptureContract.validate(capture)
        self.document = document; self.now = now; self.id = id
        defaults = capture.defaults ?? .init()
        _ = try NotebookCaptureFields.language(defaults.language)
        _ = try NotebookCaptureFields.language(defaults.meaningLanguage)
        _ = try NotebookCaptureFields.language(defaults.translationLanguage)
        _ = try provenance(nil)
        for (index, meaning) in (capture.meanings ?? []).enumerated() { try addMeaning(meaning, path: "meaning.\(index)") }
        for (index, entry) in capture.entries.enumerated() { try addEntry(entry, path: "entry.\(index)") }
        for (index, relation) in (capture.relations ?? []).enumerated() { try addRelation(relation, path: "relation.\(index)") }
    }

    private func provenance(_ status: String?) throws -> VocabularySemanticProvenance {
        guard let value = VocabularySemanticProvenance.Status(rawValue: status ?? defaults.status ?? "confirmed") else {
            throw NotebookToolError.invalid("Unknown adoption status.")
        }
        return .init(origin: .model, status: value, source: defaults.source ?? "CLI capture")
    }

    private mutating func addMeaning(_ input: NotebookCaptureTask.Meaning, path: String) throws {
        let ref = try NotebookCaptureFields.text(input.ref, limit: 200, nonempty: true)
        guard nodes[ref] == nil else { throw NotebookToolError.invalid("Meaning refs must be unique within the capture.") }
        let nodeID: UUID
        if let existing = input.id {
            // Referencing an existing node must not silently replace its names, cues or status.
            guard input.title == nil, input.kind == nil, input.language == nil, input.aliases == nil,
                  input.definition == nil, input.cues == nil, input.status == nil else {
                throw NotebookToolError.invalid("An existing meaning accepts ref, id and additive categories only. " +
                    "Use resource operations to edit it.")
            }
            guard document.semantics.nodes.contains(where: { $0.id == existing }) else {
                throw NotebookToolError(code: .notFound, message: "Referenced meaning does not exist.")
            }
            nodeID = existing
        } else {
            nodeID = id(path)
            let language = try NotebookCaptureFields.language(input.language ?? defaults.meaningLanguage)
            let title = try NotebookCaptureFields.text(input.title ?? "", limit: 4_096, nonempty: true)
            var labels = [VocabularyMeaningLabel(id: id(path + ".label"), text: title, language: language)]
            for (index, alias) in (input.aliases ?? []).enumerated() {
                let language = try NotebookCaptureFields.language(alias.language ?? defaults.meaningLanguage)
                // One preferred label per language; additional same-language labels are aliases.
                labels.append(.init(id: id(path + ".alias.\(index)"), text: alias.text, language: language,
                    preferred: !labels.contains(where: { $0.language == language && $0.preferred })))
            }
            guard let kind = VocabularyMeaningNode.Kind(rawValue: input.kind ?? "concept") else {
                throw NotebookToolError.invalid("Unknown meaning kind.")
            }
            let provenance = try provenance(input.status)
            document.semantics.nodes.append(.init(id: nodeID, kind: kind, labels: labels,
                definition: input.definition ?? "", provenance: provenance, createdAt: now, updatedAt: now))
            for (index, text) in (input.cues ?? []).enumerated() {
                let cueID = id(path + ".cue.\(index)")
                document.semantics.cues.append(.init(id: cueID, text: text, language: language))
                document.semantics.cueTargets.append(.init(id: id(path + ".target.\(index)"), cueID: cueID,
                    nodeID: nodeID, provenance: provenance))
            }
        }
        var categories: [NotebookToolJSON] = []
        for (offset, reference) in (input.categories ?? []).enumerated() {
            let matches = document.classification.categories.filter {
                $0.id == UUID(uuidString: reference) || $0.key == reference
            }
            guard matches.count == 1, let category = matches.first, !category.isRetired else {
                throw NotebookToolError.invalid("Category reference must name one active category UUID or catalog key.")
            }
            let existing = document.classification.memberships.first { $0.nodeID == nodeID && $0.categoryID == category.id }
            let membershipID = existing?.id ?? id(path + ".category.\(offset)")
            if existing == nil {
                document.classification.memberships.append(.init(id: id(path + ".category.\(offset)"),
                    nodeID: nodeID, categoryID: category.id, provenance: try provenance(input.status)))
                categoryMembershipCount += 1
            }
            categories.append(.object(["categoryID": .string(category.id.uuidString),
                "key": category.key.map(NotebookToolJSON.string) ?? .null,
                "membershipID": .string(membershipID.uuidString), "created": .bool(existing == nil)]))
        }
        nodes[ref] = nodeID
        meanings.append(.object(["ref": .string(ref), "nodeID": .string(nodeID.uuidString),
            "created": .bool(input.id == nil), "categories": .array(categories)]))
    }

    private mutating func addEntry(_ input: NotebookCaptureTask.Entry, path: String) throws {
        let expression = try NotebookCaptureFields.text(input.expression, limit: 32_000, nonempty: true)
        guard let language = try NotebookCaptureFields.language(input.language ?? defaults.language),
              let kind = VocabularyEntry.Kind(rawValue: input.kind ?? "word") else {
            throw NotebookToolError.invalid("Supply entry language or defaults.language and a supported kind.")
        }
        let dictionary = try NotebookCaptureFields.text(input.dictionaryForm ?? expression, limit: 32_000, nonempty: true)
        let key = VocabularyIdentityPolicy.entryKey(expression: expression, language: language, kind: kind)
        let existing = document.catalog.firstIndex { VocabularyIdentityPolicy.entryKey($0) == key }
        let entry: Int
        if let existing { entry = existing } else {
            entry = document.catalog.count
            document.catalog.append(.init(id: id(path), expression: expression, dictionaryForm: dictionary,
                language: language, kind: kind, senses: [], createdAt: now, updatedAt: now))
        }
        var outcomes: [NotebookToolJSON] = []
        for (index, sense) in input.senses.enumerated() {
            outcomes.append(try addSense(sense, entry: entry, path: path + ".sense.\(index)"))
        }
        document.catalog[entry].updatedAt = now
        entries.append(.object(["entryID": .string(document.catalog[entry].id.uuidString), "expression": .string(expression),
            "language": .string(language.rawValue), "created": .bool(existing == nil), "senses": .array(outcomes)]))
    }

    private mutating func addSense(_ input: NotebookCaptureTask.Sense, entry: Int, path: String) throws -> NotebookToolJSON {
        let senseID: UUID
        if let existing = input.id {
            guard input.meaning == nil, input.meaningLanguage == nil, input.note == nil else {
                throw NotebookToolError.invalid("Existing senses accept examples, tags and associations; use update for replacements.")
            }
            guard document.catalog[entry].senses.contains(where: { $0.id == existing }) else {
                throw NotebookToolError(code: .notFound, message: "Referenced sense does not belong to the selected entry.")
            }
            senseID = existing
        } else {
            senseID = id(path)
            let meaning = try NotebookCaptureFields.text(input.meaning ?? "", limit: 32_000, nonempty: true)
            let language = try NotebookCaptureFields.language(input.meaningLanguage ?? defaults.meaningLanguage)
            document.catalog[entry].senses.append(.init(id: senseID, meaning: meaning, meaningLanguage: language,
                meaningOrigin: .ai, createdAt: now, updatedAt: now, createdWithoutContext: true))
        }
        let usageIDs = try addExamples(input.examples ?? [], entry: document.catalog[entry], senseID: senseID, path: path)
        guard let sense = document.catalog[entry].senses.firstIndex(where: { $0.id == senseID }) else {
            throw VocabularyError.invalidArchive
        }
        if let note = input.note { document.catalog[entry].senses[sense].note = note }
        document.catalog[entry].senses[sense].tags = try NotebookCaptureFields.tags(
            document.catalog[entry].senses[sense].tags + (input.tags ?? []))
        var associations: [NotebookToolJSON] = []
        for (index, association) in (input.associations ?? []).enumerated() {
            let mappingID = try addAssociation(association, senseID: senseID, evidence: usageIDs, path: path + ".mapping.\(index)")
            associations.append(.string(mappingID.uuidString))
        }
        senseCount += 1; exampleCount += usageIDs.count
        return .object(["senseID": .string(senseID.uuidString), "created": .bool(input.id == nil),
            "usageIDs": .array(usageIDs.map { .string($0.uuidString) }), "associationIDs": .array(associations)])
    }

    private mutating func addExamples(_ inputs: [NotebookCaptureExample], entry: VocabularyEntry, senseID: UUID, path: String) throws -> [UUID] {
        var result: [UUID] = []
        for (index, input) in inputs.enumerated() {
            var input = input
            input.meaningLanguage = input.meaningLanguage ?? defaults.meaningLanguage
            input.translationLanguage = input.translationLanguage ?? defaults.translationLanguage ?? defaults.meaningLanguage
            input.sourceKind = input.sourceKind ?? defaults.sourceKind ?? "generated"
            let usage = try NotebookCaptureFields.example(input, expression: entry.expression, id: id(path + ".example.\(index)"), now: now)
            let existing = document.entries.first { $0.id == entry.id }?.senses.flatMap { sense in
                sense.examples.map { (sense.id, $0) }
            }.first { VocabularyIdentityPolicy.exampleKey($0.1) == VocabularyIdentityPolicy.exampleKey(usage) }
            if let existing {
                let (owner, retained) = existing
                guard owner == senseID else {
                    throw NotebookToolError(code: .conflict, message: "This usage belongs to another sense. Append to its owner.")
                }
                // A capture is additive. Reusing evidence never overwrites a saved translation or meaning.
                let meaningMatches = usage.meaning.isEmpty || usage.meaning == retained.meaning &&
                    usage.meaningLanguage == retained.meaningLanguage
                let translationMatches = usage.translation.isEmpty || usage.translation == retained.translation &&
                    usage.translationLanguage == retained.translationLanguage
                guard meaningMatches, translationMatches else {
                    throw NotebookToolError(code: .conflict, message: "Existing usage differs. Use append or explicit resource edits.")
                }
                result.append(retained.id)
                continue
            }
            let occurrenceID = id(path + ".occurrence.\(index)")
            document.sources.append(.init(id: usage.sourceID, text: usage.text, kind: usage.sourceKind,
                appBundleIdentifier: nil, encounteredAt: now))
            document.occurrences.append(.init(id: occurrenceID, sourceID: usage.sourceID, ranges: usage.ranges))
            document.interpretations.append(.init(id: usage.id, occurrenceID: occurrenceID, senseID: senseID,
                status: .accepted, meaning: usage.meaning, meaningLanguage: usage.meaningLanguage,
                meaningOrigin: input.meaning == nil ? .captured : .ai, translation: usage.translation,
                translationLanguage: usage.translationLanguage, completeness: usage.completeness,
                provenance: try provenance(nil), createdAt: now))
            result.append(usage.id)
        }
        return result
    }

    private mutating func addAssociation(_ input: NotebookCaptureTask.Association, senseID: UUID, evidence: [UUID], path: String) throws -> UUID {
        guard let nodeID = nodes[input.meaning], let node = document.semantics.nodes.first(where: { $0.id == nodeID }) else {
            throw NotebookToolError.invalid("Unknown meaning ref in association.")
        }
        let provenance = try provenance(input.status)
        let patternID: UUID?
        if let template = input.usage {
            patternID = id(path + ".pattern")
            guard let formality = VocabularyUsagePattern.Formality(rawValue: input.formality ?? "unspecified"),
                  let medium = VocabularyUsagePattern.Medium(rawValue: input.medium ?? "unspecified") else {
                throw NotebookToolError.invalid("Unknown usage formality or medium.")
            }
            document.semantics.patterns.append(.init(id: id(path + ".pattern"), senseID: senseID, template: template,
                formality: formality, medium: medium, collocations: input.collocations ?? [], provenance: provenance))
        } else {
            guard input.formality == nil, input.medium == nil, input.collocations == nil else {
                throw NotebookToolError.invalid("Usage attributes require usage.")
            }
            patternID = nil
        }
        let mappingID = id(path)
        document.semantics.mappings.append(.init(id: mappingID, nodeID: nodeID, senseID: senseID, patternID: patternID,
            relation: node.kind == .concept ? .expressesContent : .realizesFunction, conditions: input.conditions ?? "",
            nuance: input.nuance ?? "", evidenceIDs: Array(Set(evidence)).sorted { $0.uuidString < $1.uuidString }, provenance: provenance))
        mappingCount += 1
        return mappingID
    }

    private mutating func addRelation(_ input: NotebookCaptureTask.Relation, path: String) throws {
        guard let sourceID = nodes[input.from], let targetID = nodes[input.to],
              let kind = VocabularyMeaningRelation.Kind(rawValue: input.kind) else {
            throw NotebookToolError.invalid("Unknown meaning ref or relation kind.")
        }
        document.semantics.relations.append(.init(id: id(path), sourceID: sourceID, targetID: targetID, kind: kind,
            note: input.note ?? "", provenance: try provenance(input.status)))
    }
}
