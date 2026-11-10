import Foundation

/// One request-owned read projection exposes the same current sense content as the notebook.
/// Text is plain, images are authorized references, and provenance stays on examples. Internal
/// generation receipts, alternate legacy meanings and native formatting are not authoring input.
public nonisolated struct NotebookSenseProjection {
    private let document: VocabularyDocument
    private let sources: [UUID: VocabularySourceSnapshot]
    private let occurrences: [UUID: VocabularySourceOccurrence]
    private let examples: [UUID?: [VocabularyInterpretation]]
    private let links: [UUID: [VocabularyMeaningMapping]]
    private let nodes: [UUID: VocabularyMeaningNode]
    private let patterns: [UUID: VocabularyUsagePattern]

    public init(_ document: VocabularyDocument) {
        self.document = document
        sources = Dictionary(uniqueKeysWithValues: document.sources.map { ($0.id, $0) })
        occurrences = Dictionary(uniqueKeysWithValues: document.occurrences.map { ($0.id, $0) })
        examples = Dictionary(grouping: document.interpretations.filter { $0.status == .accepted }, by: \.senseID)
        links = Dictionary(grouping: document.semantics.mappings, by: \.senseID)
        nodes = Dictionary(uniqueKeysWithValues: document.semantics.nodes.map { ($0.id, $0) })
        patterns = Dictionary(uniqueKeysWithValues: document.semantics.patterns.map { ($0.id, $0) })
    }

    public func entry(_ entry: VocabularyEntry) throws -> NotebookToolJSON {
        var value = header(entry)
        value["senses"] = .array(try entry.senses.map { try sense($0, entry: entry) })
        return .object(value)
    }

    public func sense(_ id: UUID) throws -> NotebookToolJSON {
        guard let entry = document.catalog.first(where: { $0.senses.contains { $0.id == id } }),
              let sense = entry.senses.first(where: { $0.id == id }) else {
            throw NotebookToolError(code: .notFound, message: "Sense not found. Read its headword again.")
        }
        return try self.sense(sense, entry: entry)
    }

    public func senses() throws -> [UUID: NotebookToolJSON] {
        var result: [UUID: NotebookToolJSON] = [:]
        for entry in document.catalog {
            for sense in entry.senses { result[sense.id] = try self.sense(sense, entry: entry) }
        }
        return result
    }

    private func header(_ entry: VocabularyEntry) -> [String: NotebookToolJSON] {
        ["id": .string(entry.id.uuidString), "expression": .string(entry.expression),
         "dictionaryForm": .string(entry.dictionaryForm), "language": entry.language.map { .string($0.rawValue) } ?? .null,
         "kind": .string(entry.kind.rawValue)]
    }

    private func sense(_ sense: VocabularySense, entry: VocabularyEntry) throws -> NotebookToolJSON {
        let content: [NotebookToolJSON] = (sense.content ?? []).map { block in
            switch block.content {
            case let .text(value):
                return .object(["id": .string(block.id.uuidString), "type": .string("text"), "text": .string(value.text)])
            case let .image(image, caption):
                return .object(["id": .string(block.id.uuidString), "type": .string("image"),
                    "imageID": .string(image.digest), "caption": .string(caption),
                    "width": .integer(Int64(image.width)), "height": .integer(Int64(image.height))])
            }
        }
        let evidence = try (examples[sense.id] ?? []).map { claim -> NotebookToolJSON in
            guard let occurrence = occurrences[claim.occurrenceID], let source = sources[occurrence.sourceID] else {
                throw VocabularyError.invalidArchive
            }
            return .object(["id": .string(claim.id.uuidString), "text": .string(source.text),
                "translation": .string(claim.translation), "translationLanguage": claim.translationLanguage.map { .string($0.rawValue) } ?? .null,
                "translationVariants": try .value(claim.translationVariants), "ranges": try .value(occurrence.ranges),
                "completeness": .string(claim.completeness.rawValue),
                "source": .object(["id": .string(source.id.uuidString), "kind": .string(source.kind.rawValue),
                    "citation": .string(claim.provenance.source), "encounteredAt": .number(source.encounteredAt.timeIntervalSince1970),
                    "appBundleIdentifier": source.appBundleIdentifier.map(NotebookToolJSON.string) ?? .null])])
        }
        let semanticLinks = try (links[sense.id] ?? []).map { mapping -> NotebookToolJSON in
            guard let node = nodes[mapping.nodeID] else { throw VocabularyError.invalidArchive }
            let pattern: NotebookToolJSON
            if let id = mapping.patternID, let value = patterns[id] {
                pattern = .object(["id": .string(id.uuidString), "template": .string(value.template),
                    "slots": try .value(value.slots), "formality": .string(value.formality.rawValue),
                    "medium": .string(value.medium.rawValue), "region": .string(value.region),
                    "collocations": .array(value.collocations.map(NotebookToolJSON.string))])
            } else { pattern = .null }
            return .object(["id": .string(mapping.id.uuidString), "nodeID": .string(node.id.uuidString),
                "labels": try .value(node.labels), "kind": .string(node.kind.rawValue), "definition": .string(node.definition),
                "conditions": .string(mapping.conditions), "status": .string(mapping.provenance.status.rawValue),
                "pattern": pattern])
        }
        return .object(["id": .string(sense.id.uuidString), "entry": .object(header(entry)),
            "meaning": .string(sense.meaning), "meaningLanguage": sense.meaningLanguage.map { .string($0.rawValue) } ?? .null,
            "explanation": .array(content), "note": .string(sense.note), "tags": .array(sense.tags.map(NotebookToolJSON.string)),
            "examples": .array(evidence), "semanticLinks": .array(semanticLinks)])
    }
}
