import SwiftUI

/// A window-owned name/description draft leaves the semantic record's hidden labels, roles,
/// relations and provenance intact. The archive merges this small edit with concurrent work.
struct VocabularyMeaningEditor: View {
    @ObservedObject var store: VocabularyStore
    // A live language change redraws the presenting window. State pins the editing receipt
    // to the label originally shown, so an unfinished French name cannot overwrite English.
    @State private var baseline: VocabularySemanticIndex
    @State private var original: VocabularyMeaningNode
    @State private var editedLabel: VocabularyMeaningLabel
    private let linking: VocabularySelection?
    private let onSaved: (UUID) -> Void
    @State private var title: String
    @State private var definition: String
    @State private var kind: VocabularyMeaningNode.Kind
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, node: VocabularyMeaningNode? = nil, linking: VocabularySelection? = nil,
         preferredLanguages: [LearningLanguage] = VocabularyMeaningLabelPolicy.preferredLanguages(),
         onSaved: @escaping (UUID) -> Void = { _ in }) {
        self.store = store; self.linking = linking; self.onSaved = onSaved
        let value = node ?? VocabularyMeaningNode(id: UUID(), labels: [.init(text: "", language: preferredLanguages.first)])
        let label = VocabularyMeaningLabelPolicy.label(for: value, languages: preferredLanguages) ?? value.labels[0]
        _baseline = State(initialValue: store.semantics)
        _original = State(initialValue: value)
        _editedLabel = State(initialValue: label)
        _title = State(initialValue: label.text)
        _definition = State(initialValue: value.definition)
        _kind = State(initialValue: value.kind)
    }

    var body: some View {
        VocabularySemanticEditorFrame(title: String(localized: "Group by meaning", table: "Vocabulary"), saving: saving,
            canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, failure: failure, save: save) {
            Section {
                HStack(spacing: 8) {
                    TextField(String(localized: "What do you want to express?", table: "Vocabulary"), text: $title)
                        .accessibilityIdentifier("vocabularyMeaningName")
                    // A fallback may be in a different language. Display its actual tag and keep
                    // that same label identity on Save, rather than relabeling it as the preference.
                    VocabularyExpressionLanguageBadge(language: editedLabel.language)
                }
                TextField(String(localized: "Description (optional)", table: "Vocabulary"), text: $definition, axis: .vertical)
                    .accessibilityIdentifier("vocabularyMeaningDescription")
            }
            // Existing node types are never inferred from a renamed label. Creation retains a
            // small optional purpose choice so a communication goal need not become an event.
            if !baseline.nodes.contains(where: { $0.id == original.id }) {
                DisclosureGroup(String(localized: "Details", table: "Learning")) {
                    Picker(String(localized: "Use this to describe", table: "Vocabulary"), selection: $kind) {
                        Text(String(localized: "Things and situations", table: "Vocabulary")).tag(VocabularyMeaningNode.Kind.concept)
                        Text(String(localized: "Requests, suggestions and attitudes", table: "Vocabulary"))
                            .tag(VocabularyMeaningNode.Kind.function)
                    }
                }
            }
        }
    }

    private func save() {
        var edited = baseline
        var value = VocabularySemanticEditingPolicy.rename(original, title: title, definition: definition, labelID: editedLabel.id)
        if let index = edited.nodes.firstIndex(where: { $0.id == value.id }) {
            edited.nodes[index] = value
        } else { value.kind = kind; edited.nodes.append(value) }
        if let linking, !edited.mappings.contains(where: { $0.nodeID == value.id && $0.senseID == linking.senseID }) {
            edited.mappings.append(.init(nodeID: value.id, senseID: linking.senseID,
                relation: value.kind == .concept ? .expressesContent : .realizesFunction))
        }
        saving = true
        Task {
            if await store.updateSemantics(edited, basedOn: baseline) { onSaved(value.id); dismiss() } else { failure = store.errorMessage }
            saving = false
        }
    }
}
