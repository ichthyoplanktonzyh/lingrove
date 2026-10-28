import SwiftUI

/// Classification starts from a concrete expression meaning. Hidden evidence and syntax stay
/// on the original mapping; changing its destination cannot silently broaden its applicability.
struct VocabularyMeaningMappingEditor: View {
    @ObservedObject var store: VocabularyStore
    private let baseline: VocabularySemanticIndex
    private let original: VocabularyMeaningMapping?
    private let fixedSenseID: UUID?
    private let fixedNodeID: UUID?
    @State private var nodeID: UUID?
    @State private var senseID: UUID?
    @State private var conditions = ""
    @State private var nuance = ""
    @State private var showingDetails = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.vocabularyMeaningLanguages) private var meaningLanguages

    init(store: VocabularyStore, senseID: UUID? = nil, nodeID: UUID? = nil, mapping: VocabularyMeaningMapping? = nil) {
        self.store = store; baseline = store.semantics; original = mapping
        fixedSenseID = mapping?.senseID ?? senseID; fixedNodeID = nodeID
        _nodeID = State(initialValue: mapping?.nodeID ?? nodeID)
        _senseID = State(initialValue: mapping?.senseID ?? senseID)
        _conditions = State(initialValue: mapping?.conditions ?? "")
        _nuance = State(initialValue: mapping?.nuance ?? "")
    }
    private var node: VocabularyMeaningNode? { store.semantics.nodes.first { $0.id == nodeID } }
    private var entry: VocabularyEntry? { store.entries.first { $0.senses.contains { $0.id == senseID } } }
    private var sense: VocabularySense? { entry?.senses.first { $0.id == senseID } }
    private var pattern: VocabularyUsagePattern? { baseline.patterns.first { $0.id == original?.patternID } }

    var body: some View {
        VocabularySemanticEditorFrame(title: String(localized: "Group by meaning", table: "Vocabulary"), saving: saving,
            canSave: node != nil && sense != nil, failure: failure, save: save) {
            Section {
                if fixedSenseID == nil {
                    Picker(String(localized: "Expression", table: "Vocabulary"), selection: $senseID) {
                        Text(String(localized: "Choose an expression", table: "Vocabulary")).tag(UUID?.none)
                        ForEach(store.entries) { entry in
                            ForEach(entry.senses) { sense in
                                Text(VocabularyMeaningLabelPolicy.expressionTitle(entry, includeLanguage: true)
                                     + " · " + sense.displayTitle)
                                    .tag(Optional(sense.id))
                            }
                        }
                    }
                    if let sense, let example = sense.examples.first {
                        Text(example.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let entry, let sense {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.expression).font(.headline)
                            Spacer()
                            VocabularyExpressionLanguageBadge(language: entry.language)
                        }
                        if !sense.displayTitle.isEmpty {
                            Text(sense.displayTitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let example = sense.examples.first {
                            Text(example.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(LingroveBrand.accent.opacity(0.35))
                                        .frame(width: 2)
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if fixedNodeID == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(String(localized: "Meaning", table: "Vocabulary"), selection: $nodeID) {
                            Text(String(localized: "Choose a meaning", table: "Vocabulary")).tag(UUID?.none)
                            ForEach(store.semantics.nodes) { Text($0.title(in: meaningLanguages)).tag(Optional($0.id)) }
                        }
                        .accessibilityIdentifier("vocabularyGroupingDestination")
                        if let node, !node.definition.isEmpty {
                            Text(node.definition)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let node {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(node.title(in: meaningLanguages)).font(.headline)
                            Spacer()
                            VocabularyMeaningKindBadge(kind: node.kind)
                        }
                        if !node.definition.isEmpty {
                            Text(node.definition)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // Restrictions are visible and immutable here. A destination edit is never an
            // instruction to replace a pattern-specific claim with a whole-sense claim.
            if let pattern {
                Section(String(localized: "Used in this wording", table: "Vocabulary")) {
                    VocabularyUsagePatternSummary(pattern: pattern)
                }
            }
            DisclosureGroup(String(localized: "Details", table: "Learning"), isExpanded: $showingDetails) {
                TextField(String(localized: "Usage conditions", table: "Vocabulary"), text: $conditions, axis: .vertical)
                TextField(String(localized: "Nuance", table: "Vocabulary"), text: $nuance, axis: .vertical)
            }
        }
    }

    private func save() {
        guard let node, let sense else { return }
        let draft = original ?? .init(nodeID: node.id, senseID: sense.id)
        let value = VocabularySemanticEditingPolicy.classify(draft, under: node, conditions: conditions, nuance: nuance)
        var edited = baseline
        if let index = edited.mappings.firstIndex(where: { $0.id == value.id }) {
            edited.mappings[index] = value
        } else { edited.mappings.append(value) }
        saving = true
        Task {
            if await store.updateSemantics(edited, basedOn: baseline) { dismiss() } else { failure = store.errorMessage }
            saving = false
        }
    }
}
