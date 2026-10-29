import SwiftUI

/// One sheet owns an immutable baseline and a name/parent draft. Built-ins write only a local
/// overlay; custom records and their parent edges commit together through the app-owned store.
struct VocabularyCategoryEditor: View {
    @ObservedObject var store: VocabularyStore
    private let original: VocabularyCategory
    private let linkingNodeID: UUID?
    private let onSaved: (UUID) -> Void
    @State private var baseline: VocabularyClassificationIndex
    @State private var name: String
    @State private var definition: String
    @State private var axis: VocabularyCategory.Axis
    @State private var parentIDs: Set<UUID>
    @State private var label: VocabularyMeaningLabel
    @State private var hidden: Bool
    @State private var query = ""
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, category: VocabularyCategory? = nil, parentID: UUID? = nil, linkingNodeID: UUID? = nil,
         preferredLanguages: [LearningLanguage] = VocabularyMeaningLabelPolicy.preferredLanguages(),
         onSaved: @escaping (UUID) -> Void = { _ in }) {
        self.store = store; self.onSaved = onSaved; self.linkingNodeID = linkingNodeID
        let parent = store.classification.categories.first { $0.id == parentID }
        let original = category ?? VocabularyCategory(id: UUID(), axis: parent?.axis ?? .content,
            labels: [.init(text: "", language: preferredLanguages.first)])
        self.original = original
        let effective = VocabularyClassificationPolicy.effective(original, in: store.classification)
        let label = VocabularyMeaningLabelPolicy.label(in: effective.labels, languages: preferredLanguages) ?? effective.labels[0]
        _baseline = State(initialValue: store.classification)
        _name = State(initialValue: label.text); _definition = State(initialValue: effective.definition)
        _axis = State(initialValue: original.axis); _label = State(initialValue: label)
        _hidden = State(initialValue: store.classification.overrides.first { $0.categoryID == original.id }?.isHidden ?? false)
        _parentIDs = State(initialValue: category == nil ? Set(parentID.map { [$0] } ?? []) :
            Set(store.classification.parents.filter { $0.categoryID == original.id }.map(\.parentID)))
    }

    private var isNew: Bool { !baseline.categories.contains { $0.id == original.id } }
    private var parents: [VocabularyCategory] {
        let excluded = VocabularyClassificationPolicy.descendants(of: original.id, in: baseline)
        return baseline.categories.filter { category in
            category.axis == axis && !category.isRetired && !excluded.contains(category.id) &&
                (query.isEmpty || title(category).localizedStandardContains(query))
        }
    }
    private func title(_ category: VocabularyCategory) -> String {
        VocabularyClassificationPolicy.title(category, in: baseline, languages: languages)
    }

    var body: some View {
        VocabularySemanticEditorFrame(title: isNew ? String(localized: "New category", table: "Vocabulary") :
            String(localized: "Edit category", table: "Vocabulary"), saving: saving,
            canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, failure: failure, save: save) {
            Section {
                TextField(String(localized: "Category name", table: "Vocabulary"), text: $name)
                    .accessibilityIdentifier("vocabularyCategoryName")
                TextField(String(localized: "Description (optional)", table: "Vocabulary"), text: $definition, axis: .vertical)
                if isNew {
                    Picker(String(localized: "Category type", table: "Vocabulary"), selection: $axis) {
                        ForEach(VocabularyCategory.Axis.allCases, id: \.self) { value in Text(value.label).tag(value) }
                    }
                }
                Toggle(String(localized: "Visible", table: "Vocabulary"), isOn: Binding(get: { !hidden }, set: { hidden = !$0 }))
            }
            if original.frameworkID == nil {
                Section(String(localized: "Parent categories", table: "Vocabulary")) {
                    TextField(String(localized: "Search categories", table: "Vocabulary"), text: $query)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(parents) { category in
                                Toggle(title(category), isOn: Binding(get: { parentIDs.contains(category.id) }, set: { selected in
                                    if selected { parentIDs.insert(category.id) } else { parentIDs.remove(category.id) }
                                })).toggleStyle(.checkbox)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 125)
                }
            }
        }
        .onChange(of: axis) { _, _ in parentIDs.removeAll() }
    }

    private func save() {
        var edited = baseline, value = original
        var labels = VocabularyClassificationPolicy.effective(original, in: baseline).labels
        var renamed = label; renamed.text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let position = labels.firstIndex(where: { $0.id == label.id }) { labels[position] = renamed }
        let overlay = VocabularyCategoryOverride(categoryID: value.id,
            labels: value.frameworkID == nil ? nil : labels, definition: value.frameworkID == nil ? nil : definition, isHidden: hidden)
        edited.overrides.removeAll { $0.categoryID == value.id }
        if hidden || value.frameworkID != nil { edited.overrides.append(overlay) }
        if value.frameworkID == nil {
            value.axis = axis; value.labels = labels; value.definition = definition
            if let position = edited.categories.firstIndex(where: { $0.id == value.id }) { edited.categories[position] = value } else {
                edited.categories.append(value)
            }
            edited.parents.removeAll { $0.categoryID == value.id && !parentIDs.contains($0.parentID) }
            for parentID in parentIDs where !edited.parents.contains(where: {
            $0.categoryID == value.id && $0.parentID == parentID
        }) {
                edited.parents.append(.init(id: UUID(), categoryID: value.id, parentID: parentID))
            }
        }
        if let linkingNodeID {
            edited.memberships.append(.init(id: UUID(), nodeID: linkingNodeID, categoryID: value.id))
        }
        saving = true
        Task {
            if await store.updateClassification(edited, basedOn: baseline) {
                onSaved(value.id); dismiss()
            } else { failure = store.errorMessage }
            saving = false
        }
    }
}

/// The manager is a separate sheet so hidden categories stay reachable without adding noise
/// to browsing. Deleting a custom category retains all lexical and meaning records.
struct VocabularyCategoryManager: View {
    @ObservedObject var store: VocabularyStore
    @State private var editing: VocabularyCategory?
    @State private var deleting: VocabularyCategory?
    @State private var query = ""
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(String(localized: "Manage categories", table: "Vocabulary")).font(.headline).padding()
            TextField(String(localized: "Search categories", table: "Vocabulary"), text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 8)
            List {
                ForEach(store.classification.categories.filter { category in
                    !category.isRetired && (query.isEmpty || title(category).localizedStandardContains(query))
                }) { category in
                    HStack {
                        Button(title(category)) { editing = category }.buttonStyle(.plain)
                        Spacer()
                        Toggle(String(localized: "Visible", table: "Vocabulary"), isOn: Binding(get: {
                            !store.classification.overrides.contains { $0.categoryID == category.id && $0.isHidden }
                        }, set: { visible in setVisible(visible, category: category) })).toggleStyle(.checkbox)
                        Button { editing = category } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).accessibilityLabel(String(localized: "Edit category", table: "Vocabulary"))
                        if category.frameworkID == nil {
                            Button { deleting = category } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel(String(localized: "Delete category", table: "Vocabulary"))
                        }
                    }
                }
            }
            HStack { Spacer(); Button(String(localized: "Done", table: "Vocabulary")) { dismiss() } }.padding()
        }
        .frame(width: 560, height: 460)
        .sheet(item: $editing) { category in VocabularyCategoryEditor(store: store, category: category, preferredLanguages: languages) }
        .confirmationDialog(String(localized: "Delete this category?", table: "Vocabulary"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(String(localized: "Delete category", table: "Vocabulary"), role: .destructive) {
                    if let deleting {
                        let baseline = store.classification; var edited = baseline
                        do {
                            try VocabularyClassificationPolicy.removeCategory(deleting.id, from: &edited)
                            Task { _ = await store.updateClassification(edited, basedOn: baseline) }
                        } catch { store.errorMessage = error.localizedDescription }
                    }
                    deleting = nil
                }
            }
    }

    private func title(_ category: VocabularyCategory) -> String {
        VocabularyClassificationPolicy.title(category, in: store.classification, languages: languages)
    }
    private func setVisible(_ visible: Bool, category: VocabularyCategory) {
        let baseline = store.classification; var edited = baseline
        if let position = edited.overrides.firstIndex(where: { $0.categoryID == category.id }) {
            edited.overrides[position].isHidden = !visible
        } else { edited.overrides.append(.init(categoryID: category.id, isHidden: !visible)) }
        Task { _ = await store.updateClassification(edited, basedOn: baseline) }
    }
}
