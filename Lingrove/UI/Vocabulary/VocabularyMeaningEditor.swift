import SwiftUI

/// A sheet-owned draft completes one meaning task: name, expression links and categories. Child
/// pickers only return values; the app-owned store saves both indexes atomically on the final Save.
struct VocabularyMeaningEditor: View {
    @ObservedObject var store: VocabularyStore
    @State private var draft: VocabularyMeaningDraft
    private let onSaved: (UUID) -> Void
    private let linking: VocabularySelection?
    @State private var title: String
    @State private var definition: String
    @State private var kind: VocabularyMeaningNode.Kind
    @State private var choosingCategories = false
    @State private var choosingExpressions = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, node: VocabularyMeaningNode? = nil, linking: VocabularySelection? = nil,
         categoryID: UUID? = nil,
         preferredLanguages: [LearningLanguage] = VocabularyMeaningLabelPolicy.preferredLanguages(),
         onSaved: @escaping (UUID) -> Void = { _ in }) {
        self.store = store; self.linking = linking; self.onSaved = onSaved
        let draft = VocabularyMeaningDraft(semantics: store.semantics, classification: store.classification,
            node: node, categoryID: categoryID, senseID: linking?.senseID, languages: preferredLanguages)
        let label = draft.original.labels.first { $0.id == draft.labelID }
        _draft = State(initialValue: draft)
        _title = State(initialValue: label?.text ?? "")
        _definition = State(initialValue: draft.original.definition)
        _kind = State(initialValue: draft.original.kind)
    }

    private var categoryTitle: String {
        let names = draft.classification.categories.filter { draft.categoryIDs.contains($0.id) }.map {
            VocabularyClassificationProjection.breadcrumb(for: $0.id, in: draft.classification, languages: languages)
                .suffix(2).joined(separator: " › ")
        }
        return names.isEmpty ? String(localized: "Uncategorized meanings", table: "Vocabulary") : names.joined(separator: " · ")
    }

    var body: some View {
        VocabularySemanticEditorFrame(title: draft.isNew ? String(localized: "New meaning", table: "Vocabulary") :
            String(localized: "Edit", table: "Vocabulary"), saving: saving,
            canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, failure: failure, height: 560, save: save) {
            Section {
                HStack {
                    TextField(String(localized: "What do you want to express?", table: "Vocabulary"), text: $title)
                        .accessibilityIdentifier("vocabularyMeaningName")
                    VocabularyExpressionLanguageBadge(language: draft.original.labels.first { $0.id == draft.labelID }?.language)
                }
                TextField(String(localized: "Description (optional)", table: "Vocabulary"), text: $definition, axis: .vertical)
                    .accessibilityIdentifier("vocabularyMeaningDescription")
                if draft.isNew {
                    Picker(String(localized: "Use this to describe", table: "Vocabulary"), selection: $kind) {
                        Text(VocabularyCategory.Axis.content.label).tag(VocabularyMeaningNode.Kind.concept)
                        Text(VocabularyCategory.Axis.function.label).tag(VocabularyMeaningNode.Kind.function)
                    }
                    .accessibilityIdentifier("vocabularyMeaningKind")
                }
            }
            Section(String(localized: "Categories", table: "Vocabulary")) {
                Button { choosingCategories = true } label: {
                    HStack {
                        Text(categoryTitle).foregroundStyle(.primary).lineLimit(2)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vocabularyMeaningCategories")
            }
            if draft.isNew {
                Section(String(localized: "My expressions", table: "Vocabulary")) {
                    ForEach(store.entries) { entry in
                        ForEach(entry.senses.filter { draft.senseIDs.contains($0.id) }) { sense in
                            HStack {
                                Text(entry.expression).fontWeight(.medium)
                                Text(sense.displayTitle).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    if linking == nil {
                        Button(String(localized: "Add from vocabulary", table: "Vocabulary")) { choosingExpressions = true }
                            .accessibilityIdentifier("vocabularyMeaningExpressions")
                    }
                }
            }
        }
        .sheet(isPresented: $choosingCategories) {
            VocabularyMeaningCategorySheet(store: store, node: draft.original, index: draft.classification,
                selection: draft.categoryIDs, axis: kind == .function ? .function : .content) { index, ids in
                    draft.classification = index; draft.categoryIDs = ids
                    // A single chosen axis supplies a sensible creation type. Mixed-axis
                    // membership remains possible and never rewrites an existing node's kind.
                    let axes = Set(index.categories.filter { ids.contains($0.id) }.map(\.axis))
                    if draft.isNew, axes.count == 1 { kind = axes.first == .function ? .function : .concept }
                }
        }
        .sheet(isPresented: $choosingExpressions) {
            VocabularyMeaningExpressionPicker(entries: store.entries, selected: draft.senseIDs) { draft.senseIDs = $0 }
        }
    }

    private func save() {
        let value = draft.indexes(title: title, definition: definition, kind: kind)
        saving = true
        Task {
            if await store.updateMeaningOrganization(value.semantics, basedOn: draft.semanticBaseline,
                classification: value.classification, basedOn: draft.classificationBaseline) {
                onSaved(draft.original.id); dismiss()
            } else { failure = store.errorMessage }
            saving = false
        }
    }
}

/// The meaning draft owns the selected sense IDs. This searchable picker edits a local copy,
/// distinguishing homographs by their sense summary and returning only after explicit Save.
struct VocabularyMeaningExpressionPicker: View {
    let entries: [VocabularyEntry]
    private let allowsMultiple: Bool
    @State private var selected: Set<UUID>
    @State private var query = ""
    private let onSave: (Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss

    init(entries: [VocabularyEntry], selected: Set<UUID>, allowsMultiple: Bool = true, onSave: @escaping (Set<UUID>) -> Void) {
        self.entries = entries; self.allowsMultiple = allowsMultiple
        _selected = State(initialValue: selected); self.onSave = onSave
    }

    var body: some View {
        VocabularySemanticEditorFrame(title: String(localized: "Add from vocabulary", table: "Vocabulary"), saving: false,
            canSave: true, failure: nil, save: save) {
            TextField(String(localized: "Search vocabulary", table: "Vocabulary"), text: $query)
            ForEach(entries.filter { VocabularyPolicy.matches($0, query: query) }) { entry in
                Section(entry.expression) {
                    ForEach(entry.senses) { sense in
                        Toggle(sense.displayTitle, isOn: Binding(get: { selected.contains(sense.id) }, set: { value in
                            if value {
                                if allowsMultiple { selected.insert(sense.id) } else { selected = [sense.id] }
                            } else { selected.remove(sense.id) }
                        })).toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private func save() { onSave(selected); dismiss() }
}
