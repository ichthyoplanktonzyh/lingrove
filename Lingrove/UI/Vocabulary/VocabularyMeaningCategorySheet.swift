import SwiftUI

/// A meaning page adds this small classification control. The sheet edits only memberships;
/// existing expression cards, meaning labels and usage provenance remain owned by their editors.
struct VocabularyMeaningCategoryControl: View {
    @ObservedObject var store: VocabularyStore
    let nodeID: UUID
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @State private var editing = false

    private var categories: [VocabularyCategory] {
        let ids = Set(store.classification.memberships.filter {
            $0.nodeID == nodeID && $0.provenance.status == .confirmed
        }.map(\.categoryID))
        return store.classification.categories.filter { ids.contains($0.id) && !$0.isRetired }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(categories.map { VocabularyClassificationPolicy.title($0, in: store.classification, languages: languages) }
                .joined(separator: " · "))
                .lineLimit(2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(String(localized: "Categorize", table: "Vocabulary")) { editing = true }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("vocabularyCategorizeMeaning")
        }
        .font(.callout)
        .sheet(isPresented: $editing) { VocabularyMeaningCategorySheet(store: store, nodeID: nodeID) }
    }
}

/// Membership checkboxes share a baseline, allowing several simultaneous parents/categories
/// without a sequence of intermediate writes. A new custom category may be created in place.
struct VocabularyMeaningCategorySheet: View {
    @ObservedObject var store: VocabularyStore
    let nodeID: UUID
    @State private var baseline: VocabularyClassificationIndex
    @State private var selectedIDs: Set<UUID>
    @State private var query = ""
    @State private var creating = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, nodeID: UUID) {
        self.store = store; self.nodeID = nodeID
        _baseline = State(initialValue: store.classification)
        _selectedIDs = State(initialValue: Set(store.classification.memberships.filter { $0.nodeID == nodeID }.map(\.categoryID)))
    }

    var body: some View {
        VocabularySemanticEditorFrame(title: String(localized: "Categorize", table: "Vocabulary"), saving: saving,
            canSave: true, failure: failure, save: save) {
            HStack {
                TextField(String(localized: "Search categories", table: "Vocabulary"), text: $query)
                Button(String(localized: "New category", table: "Vocabulary")) { creating = true }
            }
            ForEach(VocabularyCategory.Axis.allCases, id: \.self) { axis in
                Section(axis.label) {
                    ForEach(baseline.categories.filter { category in
                        category.axis == axis && (!category.isRetired || selectedIDs.contains(category.id)) &&
                            (query.isEmpty || title(category).localizedStandardContains(query))
                    }) { category in
                        Toggle(title(category), isOn: Binding(get: { selectedIDs.contains(category.id) }, set: { selected in
                            if selected { selectedIDs.insert(category.id) } else { selectedIDs.remove(category.id) }
                        })).toggleStyle(.checkbox)
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            VocabularyCategoryEditor(store: store, preferredLanguages: languages) { id in
                // Adopt the new directory receipt, but retain the old membership baseline: a
                // concurrent CLI addition must not become a checkbox deletion by this stale sheet.
                let memberships = baseline.memberships
                baseline = store.classification; baseline.memberships = memberships; selectedIDs.insert(id)
            }
        }
    }

    private func title(_ category: VocabularyCategory) -> String {
        VocabularyClassificationPolicy.title(category, in: baseline, languages: languages)
    }
    private func save() {
        var edited = baseline
        edited.memberships.removeAll { $0.nodeID == nodeID && !selectedIDs.contains($0.categoryID) }
        for position in edited.memberships.indices where edited.memberships[position].nodeID == nodeID &&
            selectedIDs.contains(edited.memberships[position].categoryID) && edited.memberships[position].provenance.status == .proposed {
            edited.memberships[position].provenance = .init(origin: .user, status: .confirmed)
        }
        for id in selectedIDs where !edited.memberships.contains(where: { $0.nodeID == nodeID && $0.categoryID == id }) {
            edited.memberships.append(.init(id: UUID(), nodeID: nodeID, categoryID: id))
        }
        saving = true
        Task {
            if await store.updateClassification(edited, basedOn: baseline) { dismiss() } else { failure = store.errorMessage }
            saving = false
        }
    }
}
