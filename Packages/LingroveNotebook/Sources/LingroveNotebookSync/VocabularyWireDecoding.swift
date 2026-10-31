import Foundation
import LingroveNotebook

/// One complete materialization owns the row/owner indexes and consumed keys.
/// Ordered arrays are rebuilt by rank then stable ID; SQL's contiguous positions
/// are a later local-storage concern. Missing owners never discard child rows.
nonisolated struct VocabularyWireDecoder {
    typealias Kind = VocabularyWireEntityKind
    typealias E = VocabularyWireEntity
    typealias F = VocabularyWireFields
    typealias R = VocabularyWireReading
    private struct Key: Hashable { let kind: Kind; let id: String }
    private struct Owner: Hashable { let kind: Kind; let field: String; let id: String }
    private struct Row { let entity: E; let rank: Int }
    private var types: [Kind: [Row]] = [:]
    private var owners: [Owner: [Row]] = [:]
    private var all: Set<Key> = []
    private var used: Set<Key> = []
    private let notebookID: UUID

    init(_ entities: [E], notebookID: UUID) throws {
        self.notebookID = notebookID
        let references = ["entryId","senseId","interpretationId","nodeId","patternId","mappingId"]
        for entity in entities {
            let key = Key(kind: entity.entityType, id: entity.entityID)
            guard all.insert(key).inserted else { throw VocabularyWireError.duplicateEntity }
            var fields = F(entity.fields)
            let rank = entity.entityType == .notebookSettings ? 0 : try fields.integer("rank")
            let row = Row(entity: entity, rank: rank)
            types[entity.entityType, default: []].append(row)
            for reference in references {
                if case let .string(owner) = entity.fields[reference] {
                    owners[.init(kind: entity.entityType, field: reference, id: owner), default: []].append(row)
                }
            }
        }
    }
    private func ordered(_ rows: [Row]) -> [E] {
        rows.sorted { $0.rank == $1.rank ? $0.entity.entityID < $1.entity.entityID : $0.rank < $1.rank }.map(\.entity)
    }
    private func rows(_ kind: Kind) -> [E] { ordered(types[kind] ?? []) }
    private func children(_ kind: Kind, _ field: String, _ id: UUID) -> [E] {
        ordered(owners[.init(kind: kind, field: field, id: id.uuidString.lowercased())] ?? [])
    }
    private mutating func fields(_ row: E) throws -> F {
        guard used.insert(.init(kind: row.entityType, id: row.entityID)).inserted else { throw VocabularyWireError.invalidRecord }
        var fields = F(row.fields)
        if row.entityType != .notebookSettings { _ = try fields.integer("rank") }
        return fields
    }
    private func uuid(_ row: E) throws -> UUID { try F.uuid(row.entityID) }
    private func key(_ row: E, _ expected: String) throws {
        guard row.entityID == expected else { throw VocabularyWireError.invalidRecord }
    }
    private func id(_ value: UUID) -> String { value.uuidString.lowercased() }

    mutating func decode() throws -> VocabularyDocument {
        let roots = rows(.notebookSettings)
        guard roots.count == 1, let root = roots.first else { throw VocabularyWireError.incompleteSnapshot }
        guard root.entityID == id(notebookID) else { throw VocabularyWireError.notebookMismatch }
        var settings = try fields(root)
        guard try settings.integer("documentVersion") == 8 else { throw VocabularyWireError.unsupportedVersion }
        let hasTemplates = try settings.bool("reviewTemplatesPresent"); try settings.finish()
        var entries: [VocabularyEntry] = []
        for row in rows(.entry) {
            var f = try fields(row); let entryID = try uuid(row)
            let expression = try f.string("expression"), dictionary = try f.string("dictionaryForm")
            let language = try f.optional("language", F.optionalLanguage), kind = try f.raw("kind", VocabularyEntry.Kind.self)
            let created = try f.date("createdAt"), updated = try f.date("updatedAt"); try f.finish()
            var senses: [VocabularySense] = []
            for child in children(.sense, "entryId", entryID) { senses.append(try sense(child, entryID: entryID)) }
            entries.append(.init(id: entryID, expression: expression, dictionaryForm: dictionary, language: language, kind: kind,
                                 senses: senses, createdAt: created, updatedAt: updated))
        }
        var sources: [VocabularySourceSnapshot] = []
        for row in rows(.source) {
            var f = try fields(row); let value = VocabularySourceSnapshot(id: try uuid(row), text: try f.string("text"),
                kind: try f.raw("kind", VocabularyExample.SourceKind.self), appBundleIdentifier: try f.optional("appBundleIdentifier", F.string), encounteredAt: try f.date("encounteredAt"))
            try f.finish(); sources.append(value)
        }
        var occurrences: [VocabularySourceOccurrence] = []
        for row in rows(.occurrence) {
            var f = try fields(row); let value = VocabularySourceOccurrence(id: try uuid(row), sourceID: try f.uuid("sourceId"), ranges: try R.ranges(f.take("ranges")))
            try f.finish(); occurrences.append(value)
        }
        var interpretations: [VocabularyInterpretation] = []
        for row in rows(.interpretation) {
            var f = try fields(row); let claimID = try uuid(row)
            var value = VocabularyInterpretation(id: claimID, occurrenceID: try f.uuid("occurrenceId"),
                senseID: try f.optional("senseId") { try F.uuid(F.string($0)) }, status: try f.raw("status", VocabularyInterpretation.Status.self),
                meaning: try f.string("meaning"), meaningLanguage: try f.optional("meaningLanguage", F.optionalLanguage), meaningOrigin: try f.raw("meaningOrigin", VocabularyMeaningOrigin.self),
                translation: try f.string("translation"), translationLanguage: try f.optional("translationLanguage", F.optionalLanguage), translationVariants: try R.meanings(f.take("translationVariants")),
                completeness: try f.raw("completeness", VocabularyExample.Completeness.self), provenance: try R.provenance(f.take("provenance")), createdAt: try f.date("createdAt"))
            try f.finish(); value.explanations = try explanations(.interpretationExplanation, owner: claimID, field: "interpretationId")
            interpretations.append(value)
        }
        var collections: [VocabularyCollectionItem] = []
        for row in rows(.collection) { collections.append(try collection(row)) }
        var templates: [ReviewLayoutTemplate] = []
        for row in rows(.reviewTemplate) {
            var f = try fields(row); let value = ReviewLayoutTemplate(id: try uuid(row), name: try f.string("name"), layout: try R.layout(f.take("layout")))
            try f.finish(); templates.append(value)
        }
        guard hasTemplates || templates.isEmpty else { throw VocabularyWireError.invalidRecord }
        let semantics = try semantic(), classification = try classification()
        guard used == all else { throw VocabularyWireError.incompleteSnapshot }
        return VocabularyDocument(catalog: entries, sources: sources, occurrences: occurrences, interpretations: interpretations,
            collections: collections, reviewTemplates: hasTemplates ? templates : nil, semantics: semantics, classification: classification)
    }

    private mutating func sense(_ row: E, entryID: UUID) throws -> VocabularySense {
        var f = try fields(row); guard try f.uuid("entryId") == entryID else { throw VocabularyWireError.invalidRecord }
        let senseID = try uuid(row)
        var value = VocabularySense(id: senseID, meaning: try f.string("meaning"), meaningLanguage: try f.optional("meaningLanguage", F.optionalLanguage),
            meaningOrigin: try f.raw("meaningOrigin", VocabularyMeaningOrigin.self), standaloneMeanings: try R.meanings(f.take("standaloneMeanings")),
            alternateMeanings: try R.meanings(f.take("alternateMeanings")), mergedFrom: try f.array("mergedFrom").map { try F.uuid(F.string($0)) },
            createdAt: try f.date("createdAt"), updatedAt: try f.date("updatedAt"), createdWithoutContext: try f.optional("createdWithoutContext", F.bool))
        try f.finish(); value.explanations = try explanations(.senseExplanation, owner: senseID, field: "senseId"); return value
    }
    private mutating func explanations(_ kind: Kind, owner: UUID, field: String) throws -> [LearningExplanationRecord] {
        var result: [LearningExplanationRecord] = []
        for row in children(kind, field, owner) {
            var f = try fields(row); guard try f.uuid(field) == owner else { throw VocabularyWireError.invalidRecord }
            let explanationID = try f.uuid("explanationId"); try key(row, id(owner) + ":" + id(explanationID))
            let input = try R.input(f.take("input")), language = try f.raw("language", LearningLanguage.self)
            var body = try F(f.take("result")); let text = LearningExplanationResult(meaning: try body.string("meaning"), explanation: try body.string("explanation")); try body.finish()
            let value = LearningExplanationRecord(id: explanationID, input: input, language: language, result: text, model: try f.string("model"), createdAt: try f.date("createdAt"))
            try f.finish(); result.append(value)
        }
        return result
    }
    private mutating func collection(_ row: E) throws -> VocabularyCollectionItem {
        let senseID = try uuid(row); var f = try fields(row)
        let standalone = try f.bool("isSavedWithoutContext"), note = try f.string("note"), tags = try f.array("tags").map(F.string)
        let contentPresent = try f.bool("contentPresent"), cardsPresent = try f.bool("reviewCardsPresent"), saved = try f.date("savedAt"); try f.finish()
        var selected: [UUID] = []
        for edge in children(.selectedInterpretation, "senseId", senseID) {
            var body = try fields(edge); guard try body.uuid("senseId") == senseID else { throw VocabularyWireError.invalidRecord }
            let claim = try body.uuid("interpretationId"); try key(edge, id(senseID) + ":" + id(claim)); try body.finish(); selected.append(claim)
        }
        var blocks: [VocabularyContentBlock] = []
        for block in children(.contentBlock, "senseId", senseID) {
            var body = try fields(block); guard try body.uuid("senseId") == senseID else { throw VocabularyWireError.invalidRecord }
            blocks.append(.init(id: try uuid(block), content: try R.content(body.take("content")))); try body.finish()
        }
        var legacy: VocabularyReview?, cards: [VocabularyReview] = []
        for draft in children(.reviewDraft, "senseId", senseID) {
            var body = try fields(draft); guard try body.uuid("senseId") == senseID else { throw VocabularyWireError.invalidRecord }
            let role = try body.string("role"), plan = try R.plan(body.take("plan")), retained = try body.array("preservedPlans").map(R.plan)
            try body.finish(); let value = VocabularyReview(plan: plan, preservedPlans: retained)
            if role == "legacy" {
                try key(draft, id(senseID) + ":legacy"); guard legacy == nil else { throw VocabularyWireError.duplicateEntity }; legacy = value
            } else if role == "card" {
                try key(draft, id(senseID) + ":card:" + id(plan.id)); cards.append(value)
            } else { throw VocabularyWireError.invalidRecord }
        }
        guard contentPresent || blocks.isEmpty, cardsPresent || cards.isEmpty else { throw VocabularyWireError.invalidRecord }
        return .init(senseID: senseID, interpretationIDs: selected, isSavedWithoutContext: standalone, note: note, tags: tags,
                     content: contentPresent ? blocks : nil, review: legacy, reviewCards: cardsPresent ? cards : nil, savedAt: saved)
    }

    private mutating func semantic() throws -> VocabularySemanticIndex {
        var result = VocabularySemanticIndex()
        for row in rows(.meaningNode) {
            var f = try fields(row); let nodeID = try uuid(row)
            var value = VocabularyMeaningNode(id: nodeID, kind: try f.raw("kind", VocabularyMeaningNode.Kind.self), labels: [],
                definition: try f.string("definition"), scopeNote: try f.string("scopeNote"), provenance: try R.provenance(f.take("provenance")),
                createdAt: try f.date("createdAt"), updatedAt: try f.date("updatedAt")); try f.finish()
            for child in children(.meaningLabel, "nodeId", nodeID) {
                var body = try fields(child); guard try body.uuid("nodeId") == nodeID else { throw VocabularyWireError.invalidRecord }
                value.labels.append(.init(id: try uuid(child), text: try body.string("text"), language: try body.optional("language", F.optionalLanguage), preferred: try body.bool("preferred"))); try body.finish()
            }
            for child in children(.meaningRole, "nodeId", nodeID) {
                var body = try fields(child); guard try body.uuid("nodeId") == nodeID else { throw VocabularyWireError.invalidRecord }
                value.roles.append(.init(id: try uuid(child), name: try body.string("name"), description: try body.string("description"))); try body.finish()
            }
            result.nodes.append(value)
        }
        for row in rows(.usagePattern) {
            var f = try fields(row); let patternID = try uuid(row)
            var value = VocabularyUsagePattern(id: patternID, senseID: try f.uuid("senseId"), template: try f.string("template"),
                formality: try f.raw("formality", VocabularyUsagePattern.Formality.self), medium: try f.raw("medium", VocabularyUsagePattern.Medium.self),
                region: try f.string("region"), note: try f.string("note"), collocations: try f.array("collocations").map(F.string), provenance: try R.provenance(f.take("provenance")))
            try f.finish()
            for child in children(.patternSlot, "patternId", patternID) {
                var body = try fields(child); guard try body.uuid("patternId") == patternID else { throw VocabularyWireError.invalidRecord }
                value.slots.append(.init(id: try uuid(child), name: try body.string("name"), constraint: try body.string("constraint"))); try body.finish()
            }
            result.patterns.append(value)
        }
        for row in rows(.meaningMapping) {
            var f = try fields(row); let mappingID = try uuid(row)
            var value = VocabularyMeaningMapping(id: mappingID, nodeID: try f.uuid("nodeId"), senseID: try f.uuid("senseId"),
                patternID: try f.optional("patternId") { try F.uuid(F.string($0)) }, relation: try f.raw("relation", VocabularyMeaningMapping.Relation.self),
                conditions: try f.string("conditions"), nuance: try f.string("nuance"), provenance: try R.provenance(f.take("provenance"))); try f.finish()
            for child in children(.roleBinding, "mappingId", mappingID) {
                var body = try fields(child); guard try body.uuid("mappingId") == mappingID else { throw VocabularyWireError.invalidRecord }
                value.roleBindings.append(.init(id: try uuid(child), roleID: try body.uuid("roleId"), slotID: try body.uuid("slotId"))); try body.finish()
            }
            for child in children(.mappingEvidence, "mappingId", mappingID) {
                var body = try fields(child); guard try body.uuid("mappingId") == mappingID else { throw VocabularyWireError.invalidRecord }
                let claim = try body.uuid("interpretationId"); try key(child, id(mappingID) + ":" + id(claim)); try body.finish(); value.evidenceIDs.append(claim)
            }
            result.mappings.append(value)
        }
        for row in rows(.meaningRelation) {
            var f = try fields(row); result.relations.append(.init(id: try uuid(row), sourceID: try f.uuid("sourceNodeId"), targetID: try f.uuid("targetNodeId"),
                kind: try f.raw("kind", VocabularyMeaningRelation.Kind.self), note: try f.string("note"), provenance: try R.provenance(f.take("provenance")))); try f.finish()
        }
        for row in rows(.retrievalCue) {
            var f = try fields(row); result.cues.append(.init(id: try uuid(row), text: try f.string("text"), language: try f.optional("language", F.optionalLanguage),
                kind: try f.raw("kind", VocabularyRetrievalCue.Kind.self))); try f.finish()
        }
        for row in rows(.cueTarget) {
            var f = try fields(row); result.cueTargets.append(.init(id: try uuid(row), cueID: try f.uuid("cueId"), nodeID: try f.uuid("nodeId"),
                conditions: try f.string("conditions"), provenance: try R.provenance(f.take("provenance")))); try f.finish()
        }
        return result
    }

    private mutating func classification() throws -> VocabularyClassificationIndex {
        var result = VocabularyClassificationIndex()
        for row in rows(.classificationFramework) {
            var f = try fields(row); let name = try f.string("key"), rawVersion = try f.string("version")
            guard let version = Int(rawVersion), version > 0, String(version) == rawVersion else { throw VocabularyWireError.invalidRecord }
            result.frameworks.append(.init(id: try uuid(row), key: name, version: version)); try f.finish()
        }
        for row in rows(.category) {
            var f = try fields(row); result.categories.append(.init(id: try uuid(row), axis: try f.raw("axis", VocabularyCategory.Axis.self), labels: try R.labels(f.take("labels")),
                definition: try f.string("definition"), examples: try R.categoryExamples(f.take("examples")), scopeNote: try f.string("scopeNote"),
                references: try R.categoryReferences(f.take("references")), localizations: try R.localizations(f.take("localizations")),
                frameworkID: try f.optional("frameworkId") { try F.uuid(F.string($0)) }, key: try f.optional("key", F.string), isRetired: try f.bool("isRetired"), provenance: try R.provenance(f.take("provenance")))); try f.finish()
        }
        for row in rows(.categoryParent) {
            var f = try fields(row); result.parents.append(.init(id: try uuid(row), categoryID: try f.uuid("categoryId"), parentID: try f.uuid("parentId"))); try f.finish()
        }
        for row in rows(.categoryMembership) {
            var f = try fields(row); result.memberships.append(.init(id: try uuid(row), nodeID: try f.uuid("nodeId"), categoryID: try f.uuid("categoryId"), provenance: try R.provenance(f.take("provenance")))); try f.finish()
        }
        for row in rows(.categoryOverride) {
            var f = try fields(row); result.overrides.append(.init(categoryID: try uuid(row), labels: try f.optional("labels", R.labels),
                definition: try f.optional("definition", F.string), examples: try f.optional("examples", R.categoryExamples), scopeNote: try f.optional("scopeNote", F.string),
                references: try f.optional("references", R.categoryReferences), localizations: try f.optional("localizations", R.localizations), isHidden: try f.bool("isHidden"))); try f.finish()
        }
        return result
    }
}
