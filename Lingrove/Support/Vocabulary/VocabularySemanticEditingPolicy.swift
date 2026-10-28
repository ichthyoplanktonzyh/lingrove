import Foundation

/// Ordinary notebook editors change a small, user-facing part of a richer semantic record.
/// These pure edits preserve hidden labels, roles, evidence and restrictions. The sheet owns
/// a detached draft; the archive still owns validation, conflict detection and persistence.
nonisolated enum VocabularySemanticEditingPolicy {
    static func rename(_ original: VocabularyMeaningNode, title: String, definition: String,
                       now: Date = Date(), labelID: UUID? = nil) -> VocabularyMeaningNode {
        var result = original
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = labelID.flatMap { id in result.labels.firstIndex { $0.id == id } }
        if let index = selected ?? (labelID == nil ? result.labels.firstIndex(where: \.preferred) ?? result.labels.indices.first : nil) {
            result.labels[index].text = title
        }
        result.definition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        result.updatedAt = now
        return result
    }

    /// Moving a classification preserves its sense, pattern and evidence. Only the old node's
    /// role bindings cease to be meaningful; the user never has to rebuild syntax by hand.
    static func classify(_ original: VocabularyMeaningMapping, under node: VocabularyMeaningNode,
                         conditions: String, nuance: String) -> VocabularyMeaningMapping {
        var result = original
        if result.nodeID != node.id { result.roleBindings = [] }
        result.nodeID = node.id
        result.relation = node.kind == .concept ? .expressesContent : .realizesFunction
        result.conditions = conditions
        result.nuance = nuance
        return result
    }

    /// Evidence IDs refer to accepted interpretations, including material no longer selected
    /// for a personal card. A representative example must therefore stay visibly distinct
    /// from an explicitly cited example; it is never silently promoted to supporting evidence.
    static func example(for mapping: VocabularyMeaningMapping, sense: VocabularySense) -> VocabularyExample? {
        if !mapping.evidenceIDs.isEmpty {
            return sense.examples.first { mapping.evidenceIDs.contains($0.id) }
        }
        return mapping.patternID == nil ? sense.examples.first : nil
    }
}
