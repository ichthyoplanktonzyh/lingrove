import Foundation

/// One meaning editor owns this detached value until Save. It carries category context and
/// expression choices together; cancelling any child picker simply discards its copy. The
/// archive receives both edited indexes in one transaction rather than several partial saves.
nonisolated struct VocabularyMeaningDraft {
    let semanticBaseline: VocabularySemanticIndex
    let classificationBaseline: VocabularyClassificationIndex
    let original: VocabularyMeaningNode
    let labelID: UUID
    var classification: VocabularyClassificationIndex
    var categoryIDs: Set<UUID>
    var senseIDs: Set<UUID>
    var isNew: Bool { !semanticBaseline.nodes.contains { $0.id == original.id } }

    init(semantics: VocabularySemanticIndex, classification: VocabularyClassificationIndex,
         node: VocabularyMeaningNode? = nil, categoryID: UUID? = nil, senseID: UUID? = nil,
         languages: [LearningLanguage] = []) {
        semanticBaseline = semantics; classificationBaseline = classification; self.classification = classification
        let category = classification.categories.first { $0.id == categoryID && !$0.isRetired }
        original = node ?? .init(id: UUID(), kind: category?.axis == .function ? .function : .concept,
            labels: [.init(text: "", language: languages.first)])
        labelID = VocabularyMeaningLabelPolicy.label(for: original, languages: languages)?.id ?? original.labels[0].id
        categoryIDs = node.map { node in Set(classification.memberships.filter { $0.nodeID == node.id }.map(\.categoryID)) } ??
            Set(category.map { [$0.id] } ?? [])
        senseIDs = Set(senseID.map { [$0] } ?? [])
    }

    func indexes(title: String, definition: String, kind: VocabularyMeaningNode.Kind)
        -> (semantics: VocabularySemanticIndex, classification: VocabularyClassificationIndex) {
        var semantics = semanticBaseline, classification = classification
        var node = VocabularySemanticEditingPolicy.rename(original, title: title, definition: definition, labelID: labelID)
        if let position = semantics.nodes.firstIndex(where: { $0.id == node.id }) { semantics.nodes[position] = node } else {
            node.kind = kind; semantics.nodes.append(node)
            for senseID in senseIDs {
                semantics.mappings.append(.init(nodeID: node.id, senseID: senseID,
                    relation: kind == .concept ? .expressesContent : .realizesFunction))
            }
        }
        VocabularyClassificationPolicy.assign(nodeID: node.id, categories: categoryIDs, in: &classification)
        return (semantics, classification)
    }
}
