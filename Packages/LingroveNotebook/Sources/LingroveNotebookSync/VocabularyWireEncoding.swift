import CryptoKit
import Foundation
import LingroveNotebook

/// Explicit leaf encoders make the privacy boundary visible. In particular, no
/// VocabularyReview or ReviewPlan is encoded wholesale before stripping fields:
/// binding endpoints and audio receipts never enter a public JSON value.
nonisolated enum VocabularyWireCoding {
    typealias J = VocabularyWireJSON
    static func language(_ value: LearningLanguage?) -> J { .optional(value) { .string($0.rawValue) } }
    static func ranges(_ values: [VocabularyTextRange]) -> J {
        .array(values.map { .object(["location": .number(Double($0.location)), "length": .number(Double($0.length))]) })
    }
    static func meanings(_ values: [VocabularyMeaning]) -> J { .array(values.map { .object(["text": .string($0.text), "language": language($0.language)]) }) }
    static func provenance(_ value: VocabularySemanticProvenance) -> J {
        .object(["origin": .string(value.origin.rawValue), "status": .string(value.status.rawValue),
                 "source": .string(value.source), "confidence": .optional(value.confidence, J.number)])
    }
    static func labels(_ values: [VocabularyMeaningLabel]) -> J {
        .array(values.map { .object(["id": .uuid($0.id), "text": .string($0.text), "language": language($0.language), "preferred": .bool($0.preferred)]) })
    }
    static func block(_ value: VocabularyContentBlock) -> J { .object(["id": .uuid(value.id), "content": content(value.content)]) }
    static func content(_ value: VocabularyContentBlock.Content) -> J {
        switch value {
        case let .text(text):
            var fields: [String: J] = ["type": .string("text"), "text": .string(text.text), "style": .string(text.style.rawValue), "bold": .bool(text.bold), "italic": .bool(text.italic)]
            if let runs = text.runs {
                fields["runs"] = .array(runs.map { .object(["location": .number(Double($0.location)), "length": .number(Double($0.length)), "bold": .bool($0.bold), "italic": .bool($0.italic)]) })
            }
            return .object(fields)
        case let .image(image, caption):
            return .object(["type": .string("image"), "image": .object(["digest": .string(image.digest), "width": .number(Double(image.width)),
                 "height": .number(Double(image.height)), "byteCount": .number(Double(image.byteCount))]), "caption": .string(caption)])
        }
    }
    static func layout(_ value: ReviewLayout) -> J {
        func parts(_ values: [ReviewCardPart]) -> J {
            .array(values.map { .object(["id": .uuid($0.id), "source": .string($0.source.rawValue), "blockId": .optional($0.blockID, J.uuid),
                "showCaption": .bool($0.showCaption), "content": .array($0.content.map(block))]) })
        }
        return .object(["front": parts(value.front), "back": parts(value.back)])
    }
    static func plan(_ value: ReviewPlan) -> J {
        .object(["id": .uuid(value.id), "name": .optional(value.name, J.string), "layout": .optional(value.layout, layout),
            "exampleId": .optional(value.exampleID, J.uuid), "deck": .optional(value.deck, J.string), "answer": .optional(value.answer, J.string),
            "recognition": .bool(value.recognition), "gap": .bool(value.gap), "includeNotes": .bool(value.includeNotes),
            "includeExplanation": .bool(value.includeExplanation), "includeSenseContent": .optional(value.includeSenseContent, J.bool),
            "fieldOverrides": .array(value.fieldOverrides.sorted { $0.key < $1.key }.map { .object(["field": .string($0.key), "value": .string($0.value)]) }),
            "audioKinds": .optional(value.audioKinds) { .array($0.map(\.rawValue).sorted().map(J.string)) }])
    }
    static func input(_ value: LearningExplanationInput) -> J {
        .object(["target": .string(value.target), "dictionaryForm": .string(value.dictionaryForm), "language": language(value.language),
            "kind": .string(value.kind.rawValue), "context": .string(value.context), "ranges": ranges(value.ranges), "contextKind": .string(value.contextKind.rawValue)])
    }
    static func explanation(_ value: LearningExplanationRecord) -> [String: J] {
        ["explanationId": .uuid(value.id), "input": input(value.input), "language": .string(value.language.rawValue),
         "result": .object(["meaning": .string(value.result.meaning), "explanation": .string(value.result.explanation)]),
         "model": .string(value.model), "createdAt": .date(value.createdAt)]
    }
    static func categoryExamples(_ values: [VocabularyCategoryExample]) -> J {
        .array(values.map { .object(["text": .string($0.text), "language": .optional($0.language, J.string)]) })
    }
    static func categoryReferences(_ values: [VocabularyCategoryReference]) -> J {
        .array(values.map { .object(["source": .string($0.source), "identifier": .string($0.identifier), "url": .string($0.url),
            "relationship": .string($0.relationship.rawValue), "attribution": .optional($0.attribution, J.string), "license": .optional($0.license, J.string)]) })
    }
    static func localizations(_ values: [VocabularyCategoryLocalization]) -> J {
        .array(values.map { .object(["language": .string($0.language), "name": .optional($0.name, J.string),
            "definition": .optional($0.definition, J.string), "scopeNote": .optional($0.scopeNote, J.string)]) })
    }
    static func signature(_ value: J) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One projection owns its output array. Identity/order references are derived
/// from the domain graph directly, never through local SQL rows or joined editor
/// examples. The host supplies the already reconciled canonical server book ID.
nonisolated struct VocabularyWireEncoder {
    typealias J = VocabularyWireJSON
    typealias C = VocabularyWireCoding
    private(set) var entities: [VocabularyWireEntity] = []

    mutating func append(_ kind: VocabularyWireEntityKind, _ id: String, rank: Int? = nil, _ fields: [String: J]) {
        var value = fields
        if let rank { value["rank"] = .rank(rank) }
        entities.append(.init(entityType: kind, entityID: id, fields: value))
    }
    static func id(_ value: UUID) -> String { value.uuidString.lowercased() }

    mutating func encode(_ document: VocabularyDocument, notebookID: UUID) throws -> [VocabularyWireEntity] {
        append(.notebookSettings, Self.id(notebookID), ["documentVersion": .number(Double(VocabularyDocument.currentVersion)), "reviewTemplatesPresent": .bool(document.reviewTemplates != nil)])
        for (rank, entry) in document.catalog.enumerated() {
            append(.entry, Self.id(entry.id), rank: rank, ["expression": .string(entry.expression), "dictionaryForm": .string(entry.dictionaryForm),
                "language": C.language(entry.language), "kind": .string(entry.kind.rawValue), "createdAt": .date(entry.createdAt), "updatedAt": .date(entry.updatedAt)])
            for (rank, sense) in entry.senses.enumerated() {
                append(.sense, Self.id(sense.id), rank: rank, ["entryId": .uuid(entry.id), "meaning": .string(sense.meaning),
                    "meaningLanguage": C.language(sense.meaningLanguage), "meaningOrigin": .string(sense.meaningOrigin.rawValue),
                    "standaloneMeanings": C.meanings(sense.standaloneMeanings), "alternateMeanings": C.meanings(sense.alternateMeanings),
                    "mergedFrom": .array(sense.mergedFrom.map(J.uuid)), "createdWithoutContext": .optional(sense.createdWithoutContext, J.bool),
                    "createdAt": .date(sense.createdAt), "updatedAt": .date(sense.updatedAt),
                    "isSavedWithoutContext": .bool(sense.isSavedWithoutContext), "note": .string(sense.note),
                    "tags": .array(sense.tags.map(J.string)), "savedAt": .optional(sense.savedAt, J.date),
                    "contentPresent": .bool(sense.content != nil), "reviewCardsPresent": .bool(sense.reviewCards != nil)])
                explanations(sense.explanations, kind: .senseExplanation, owner: sense.id, field: "senseId")
            }
        }
        for (rank, source) in document.sources.enumerated() {
            append(.source, Self.id(source.id), rank: rank, ["text": .string(source.text), "kind": .string(source.kind.rawValue),
                "appBundleIdentifier": .optional(source.appBundleIdentifier, J.string), "encounteredAt": .date(source.encounteredAt)])
        }
        for (rank, occurrence) in document.occurrences.enumerated() {
            append(.occurrence, Self.id(occurrence.id), rank: rank, ["sourceId": .uuid(occurrence.sourceID), "ranges": C.ranges(occurrence.ranges)])
        }
        for (rank, claim) in document.interpretations.enumerated() {
            append(.interpretation, Self.id(claim.id), rank: rank, ["occurrenceId": .uuid(claim.occurrenceID), "senseId": .optional(claim.senseID, J.uuid),
                "status": .string(claim.status.rawValue), "meaning": .string(claim.meaning), "meaningLanguage": C.language(claim.meaningLanguage),
                "meaningOrigin": .string(claim.meaningOrigin.rawValue), "translation": .string(claim.translation), "translationLanguage": C.language(claim.translationLanguage),
                "translationVariants": C.meanings(claim.translationVariants), "completeness": .string(claim.completeness.rawValue),
                "provenance": C.provenance(claim.provenance), "createdAt": .date(claim.createdAt)])
            explanations(claim.explanations, kind: .interpretationExplanation, owner: claim.id, field: "interpretationId")
        }
        for sense in document.catalog.flatMap(\.senses) {
            for (rank, block) in (sense.content ?? []).enumerated() {
                append(.contentBlock, Self.id(block.id), rank: rank, ["senseId": .uuid(sense.id), "content": C.content(block.content)])
            }
            if let review = sense.review { reviewDraft(review, senseID: sense.id, legacy: true, rank: 0) }
            for (rank, review) in (sense.reviewCards ?? []).enumerated() {
                reviewDraft(review, senseID: sense.id, legacy: false, rank: rank + (sense.review == nil ? 0 : 1))
            }
        }
        for (rank, template) in (document.reviewTemplates ?? []).enumerated() {
            append(.reviewTemplate, Self.id(template.id), rank: rank, ["name": .string(template.name), "layout": C.layout(template.layout)])
        }
        semantic(document.semantics); classification(document.classification)
        let keys = entities.map { $0.entityType.rawValue + ":" + $0.entityID }
        guard Set(keys).count == keys.count else { throw VocabularyWireError.duplicateEntity }
        return entities
    }

    private mutating func explanations(_ values: [LearningExplanationRecord], kind: VocabularyWireEntityKind, owner: UUID, field: String) {
        for (rank, value) in values.enumerated() {
            var fields = C.explanation(value); fields[field] = .uuid(owner)
            append(kind, Self.id(owner) + ":" + Self.id(value.id), rank: rank, fields)
        }
    }
    private mutating func reviewDraft(_ value: VocabularyReview, senseID: UUID, legacy: Bool, rank: Int) {
        let key = Self.id(senseID) + (legacy ? ":legacy" : ":card:" + Self.id(value.plan.id))
        append(.reviewDraft, key, rank: rank, ["senseId": .uuid(senseID), "role": .string(legacy ? "legacy" : "card"),
            "plan": C.plan(value.plan), "preservedPlans": .array(value.preservedPlans.map(C.plan))])
    }

    private mutating func semantic(_ index: VocabularySemanticIndex) {
        for (rank, node) in index.nodes.enumerated() {
            append(.meaningNode, Self.id(node.id), rank: rank, ["kind": .string(node.kind.rawValue), "definition": .string(node.definition),
                "scopeNote": .string(node.scopeNote), "provenance": C.provenance(node.provenance), "createdAt": .date(node.createdAt), "updatedAt": .date(node.updatedAt)])
            for (rank, label) in node.labels.enumerated() {
                append(.meaningLabel, Self.id(label.id), rank: rank, ["nodeId": .uuid(node.id), "text": .string(label.text), "language": C.language(label.language), "preferred": .bool(label.preferred)])
            }
            for (rank, role) in node.roles.enumerated() {
                append(.meaningRole, Self.id(role.id), rank: rank, ["nodeId": .uuid(node.id), "name": .string(role.name), "description": .string(role.description)])
            }
        }
        for (rank, pattern) in index.patterns.enumerated() {
            append(.usagePattern, Self.id(pattern.id), rank: rank, ["senseId": .uuid(pattern.senseID), "template": .string(pattern.template),
                "formality": .string(pattern.formality.rawValue), "medium": .string(pattern.medium.rawValue), "region": .string(pattern.region),
                "note": .string(pattern.note), "collocations": .array(pattern.collocations.map(J.string)), "provenance": C.provenance(pattern.provenance)])
            for (rank, slot) in pattern.slots.enumerated() {
                append(.patternSlot, Self.id(slot.id), rank: rank, ["patternId": .uuid(pattern.id), "name": .string(slot.name), "constraint": .string(slot.constraint)])
            }
        }
        for (rank, mapping) in index.mappings.enumerated() {
            append(.meaningMapping, Self.id(mapping.id), rank: rank, ["nodeId": .uuid(mapping.nodeID), "senseId": .uuid(mapping.senseID),
                "patternId": .optional(mapping.patternID, J.uuid), "relation": .string(mapping.relation.rawValue), "conditions": .string(mapping.conditions),
                "nuance": .string(mapping.nuance), "provenance": C.provenance(mapping.provenance)])
            for (rank, binding) in mapping.roleBindings.enumerated() {
                append(.roleBinding, Self.id(binding.id), rank: rank, ["mappingId": .uuid(mapping.id), "roleId": .uuid(binding.roleID), "slotId": .uuid(binding.slotID)])
            }
            for (rank, evidence) in mapping.evidenceIDs.enumerated() {
                append(.mappingEvidence, Self.id(mapping.id) + ":" + Self.id(evidence), rank: rank,
                       ["mappingId": .uuid(mapping.id), "interpretationId": .uuid(evidence)])
            }
        }
        for (rank, relation) in index.relations.enumerated() {
            append(.meaningRelation, Self.id(relation.id), rank: rank, ["sourceNodeId": .uuid(relation.sourceID), "targetNodeId": .uuid(relation.targetID),
                "kind": .string(relation.kind.rawValue), "note": .string(relation.note), "provenance": C.provenance(relation.provenance)])
        }
        for (rank, cue) in index.cues.enumerated() {
            append(.retrievalCue, Self.id(cue.id), rank: rank, ["text": .string(cue.text), "language": C.language(cue.language), "kind": .string(cue.kind.rawValue)])
        }
        for (rank, target) in index.cueTargets.enumerated() {
            append(.cueTarget, Self.id(target.id), rank: rank, ["cueId": .uuid(target.cueID), "nodeId": .uuid(target.nodeID),
                "conditions": .string(target.conditions), "provenance": C.provenance(target.provenance)])
        }
    }

    private mutating func classification(_ index: VocabularyClassificationIndex) {
        for (rank, framework) in index.frameworks.enumerated() {
            append(.classificationFramework, Self.id(framework.id), rank: rank, ["key": .string(framework.key), "version": .string(String(framework.version))])
        }
        for (rank, category) in index.categories.enumerated() {
            append(.category, Self.id(category.id), rank: rank, ["axis": .string(category.axis.rawValue), "labels": C.labels(category.labels),
                "definition": .string(category.definition), "examples": C.categoryExamples(category.examples), "scopeNote": .string(category.scopeNote),
                "references": C.categoryReferences(category.references), "localizations": C.localizations(category.localizations),
                "frameworkId": .optional(category.frameworkID, J.uuid), "key": .optional(category.key, J.string), "isRetired": .bool(category.isRetired),
                "provenance": C.provenance(category.provenance)])
        }
        for (rank, edge) in index.parents.enumerated() {
            append(.categoryParent, Self.id(edge.id), rank: rank, ["categoryId": .uuid(edge.categoryID), "parentId": .uuid(edge.parentID)])
        }
        for (rank, membership) in index.memberships.enumerated() {
            append(.categoryMembership, Self.id(membership.id), rank: rank, ["nodeId": .uuid(membership.nodeID),
                "categoryId": .uuid(membership.categoryID), "provenance": C.provenance(membership.provenance)])
        }
        for (rank, overlay) in index.overrides.enumerated() {
            append(.categoryOverride, Self.id(overlay.categoryID), rank: rank, ["labels": .optional(overlay.labels, C.labels),
                "definition": .optional(overlay.definition, J.string), "examples": .optional(overlay.examples, C.categoryExamples),
                "scopeNote": .optional(overlay.scopeNote, J.string), "references": .optional(overlay.references, C.categoryReferences),
                "localizations": .optional(overlay.localizations, C.localizations), "isHidden": .bool(overlay.isHidden)])
        }
    }
}
