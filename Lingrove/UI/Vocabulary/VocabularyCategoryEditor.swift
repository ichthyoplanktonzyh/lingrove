import SwiftUI

/// One sheet owns an immutable baseline and a name/parent draft. Built-ins write only a local
/// overlay; custom records and their parent edges commit together through the app-owned store.
struct VocabularyCategoryEditor: View {
    @ObservedObject var store: VocabularyStore
    // SwiftUI may recreate this view value while a child sheet is presented. Pin the new
    // category and its label IDs to the editing lifetime, just like the text-field state.
    @State private var original: VocabularyCategory
    private let linkingNodeID: UUID?
    private let onSaved: (UUID) -> Void
    private let onDraftSaved: ((VocabularyClassificationIndex, UUID) -> Void)?
    @State private var usesCatalogLabels = false
    @State private var baseline: VocabularyClassificationIndex
    @State private var name: String
    @State private var definition: String
    @State private var axis: VocabularyCategory.Axis
    @State private var parentIDs: Set<UUID>
    @State private var expanded: Set<String>
    @State private var label: VocabularyMeaningLabel
    @State private var hidden: Bool
    @State private var query = ""
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.dismiss) private var dismiss

    init(
        store: VocabularyStore,
        category: VocabularyCategory? = nil,
        parentID: UUID? = nil,
        linkingNodeID: UUID? = nil,
        axis: VocabularyCategory.Axis = .content,
        draft: VocabularyClassificationIndex? = nil,
        preferredLanguages: [LearningLanguage] = VocabularyMeaningLabelPolicy.preferredLanguages(),
        onDraftSaved: ((VocabularyClassificationIndex, UUID) -> Void)? = nil,
        onSaved: @escaping (UUID) -> Void = { _ in }
    ) {
        self.store = store
        self.onSaved = onSaved
        self.onDraftSaved = onDraftSaved
        self.linkingNodeID = linkingNodeID
        let initialIndex = draft ?? store.classification
        let parent = initialIndex.categories.first { $0.id == parentID }
        let original = category ?? VocabularyCategory(
            id: UUID(),
            axis: parent?.axis ?? axis,
            labels: [.init(text: "", language: preferredLanguages.first)]
        )
        _original = State(initialValue: original)
        let effective = VocabularyClassificationPolicy.effective(original, in: initialIndex)
        let label = VocabularyMeaningLabelPolicy.label(in: effective.labels, languages: preferredLanguages) ?? effective.labels[0]
        let initialParents: Set<UUID> = category == nil
            ? Set(parentID.map { [$0] } ?? [])
            : Set(initialIndex.parents.filter { $0.categoryID == original.id }.map(\.parentID))
        _baseline = State(initialValue: initialIndex)
        _name = State(initialValue: label.text)
        _definition = State(initialValue: effective.definition)
        _axis = State(initialValue: original.axis)
        _label = State(initialValue: label)
        _hidden = State(initialValue: initialIndex.overrides.first { $0.categoryID == original.id }?.isHidden ?? false)
        _parentIDs = State(initialValue: initialParents)
        _expanded = State(initialValue: VocabularyClassificationProjection.expansionPaths(
            for: initialParents,
            in: initialIndex,
            includeHidden: true
        ))
    }

    private var isNew: Bool {
        !baseline.categories.contains { $0.id == original.id }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedParents: [VocabularyCategory] {
        baseline.categories.filter { parentIDs.contains($0.id) }
    }

    private var parentRows: [VocabularyClassificationProjection.Row] {
        let excluded = VocabularyClassificationPolicy.descendants(of: original.id, in: baseline)
        return VocabularyClassificationProjection.rows(
            baseline,
            nodes: store.semantics.nodes,
            languages: languages,
            expanded: expanded,
            query: query,
            includeHidden: true,
            excludedIDs: excluded
        ).filter { $0.category.axis == axis }
    }

    private func title(_ category: VocabularyCategory) -> String {
        VocabularyClassificationPolicy.title(category, in: baseline, languages: languages)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            metadataSection
            if original.frameworkID == nil {
                Divider()
                parentPickerSection
            } else {
                Spacer(minLength: 0)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            }
            Divider()
            sheetFooter
        }
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(saving)
        .onChange(of: axis) { _, _ in
            parentIDs.removeAll()
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: axis.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(axis.tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(axis.tint.opacity(0.12))
                )
            Text(
                isNew
                    ? String(localized: "New category", table: "Vocabulary")
                    : String(localized: "Edit category", table: "Vocabulary")
            )
            .font(.headline)
            if !isNew {
                Text(original.frameworkID == nil ? String(localized: "Custom") : String(localized: "Built-in", table: "Vocabulary"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isNew { Toggle(
                String(localized: "Visible", table: "Vocabulary"),
                isOn: Binding(get: { !hidden }, set: { hidden = !$0 })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(String(localized: "Category name", table: "Vocabulary"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("vocabularyCategoryName")

                if isNew {
                    Picker(String(localized: "Category type", table: "Vocabulary"), selection: $axis) {
                        ForEach(VocabularyCategory.Axis.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 195)
                }
            }

            TextField(String(localized: "Description (optional)", table: "Vocabulary"), text: $definition)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.018))
        .disabled(saving)
    }

    private var parentPickerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "Parent categories", table: "Vocabulary"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if !selectedParents.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(selectedParents) { parent in
                                Button {
                                    parentIDs.remove(parent.id)
                                } label: {
                                    HStack(spacing: 3.5) {
                                        Text(title(parent))
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 9.5))
                                            .opacity(0.75)
                                    }
                                    .foregroundStyle(axis.tint)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(axis.tint.opacity(0.12))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Spacer()
                }

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "Search categories", table: "Vocabulary"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .frame(width: 175)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)

            List {
                ForEach(parentRows) { row in
                    parentRow(row)
                }
            }
            .listStyle(.inset)
            .disabled(saving)
        }
    }

    private func parentRow(_ row: VocabularyClassificationProjection.Row) -> some View {
        let isSelected = parentIDs.contains(row.category.id)
        let isExpanded = expanded.contains(row.id) || !query.isEmpty
        let parentTrail = row.breadcrumb.dropLast().joined(separator: " › ")

        return HStack(spacing: 6) {
            Button {
                if !expanded.insert(row.id).inserted {
                    expanded.remove(row.id)
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 13, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(row.hasChildren ? 1 : 0)
            .disabled(!row.hasChildren)

            Toggle(isOn: Binding(
                get: { parentIDs.contains(row.category.id) },
                set: { selected in
                    if selected {
                        parentIDs.insert(row.category.id)
                    } else {
                        parentIDs.remove(row.category.id)
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: row.depth == 0 ? row.symbolName : (row.hasChildren ? "folder" : "tag"))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? axis.tint : .secondary)
                        .frame(width: 14)
                    Text(row.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if !query.isEmpty && !parentTrail.isEmpty {
                        Text(parentTrail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 2)
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 14)
        .padding(.vertical, 1)
    }

    private var sheetFooter: some View {
        HStack {
            if original.frameworkID != nil, baseline.overrides.contains(where: { $0.categoryID == original.id }) {
                Button(String(localized: "Restore defaults", table: "Vocabulary")) {
                    let raw = VocabularyMeaningLabelPolicy.label(in: original.labels, languages: languages) ?? original.labels[0]
                    label = raw; name = raw.text; definition = original.definition; hidden = false; usesCatalogLabels = true
                }
                .disabled(saving)
                .accessibilityIdentifier("vocabularyRestoreCategoryDefaults")
            }
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(saving)

            Button(String(localized: "Save", table: "Vocabulary"), action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving || !canSave)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func save() {
        var edited = baseline, value = original
        var labels = usesCatalogLabels ? original.labels : VocabularyClassificationPolicy.effective(original, in: baseline).labels
        var renamed = label
        renamed.text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let position = labels.firstIndex(where: { $0.id == label.id }) {
            labels[position] = renamed
        }
        let overlay = VocabularyCategoryOverride(
            categoryID: value.id,
            labels: value.frameworkID == nil ? nil : labels,
            definition: value.frameworkID == nil ? nil : definition,
            isHidden: hidden
        )
        edited.overrides.removeAll { $0.categoryID == value.id }
        if hidden || value.frameworkID != nil && (labels != original.labels || definition != original.definition) {
            edited.overrides.append(overlay)
        }
        if value.frameworkID == nil {
            value.axis = axis
            value.labels = labels
            value.definition = definition
            if let position = edited.categories.firstIndex(where: { $0.id == value.id }) {
                edited.categories[position] = value
            } else {
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
        do { try VocabularyClassificationPolicy.validate(edited, nodes: store.semantics.nodes) } catch {
            failure = error.localizedDescription; return
        }
        if let onDraftSaved { onDraftSaved(edited, value.id); dismiss(); return }
        saving = true
        Task {
            if await store.updateClassification(edited, basedOn: baseline) {
                onSaved(value.id)
                dismiss()
            } else {
                failure = store.errorMessage
            }
            saving = false
        }
    }
}

/// Hierarchical category manager sheet so hidden and custom categories remain easy to inspect,
/// toggle, rename, or remove without dumping 250 flat rows in a single ungrouped list.
struct VocabularyCategoryManager: View {
    @ObservedObject var store: VocabularyStore
    @State private var editing: VocabularyCategory?
    @State private var deleting: VocabularyCategory?
    @State private var creating = false
    @State private var activeAxis: VocabularyCategory.Axis = .content
    @State private var expanded: Set<String> = []
    @State private var query = ""
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.dismiss) private var dismiss

    private var visibleRows: [VocabularyClassificationProjection.Row] {
        let rows = VocabularyClassificationProjection.rows(
            store.classification,
            nodes: store.semantics.nodes,
            languages: languages,
            expanded: expanded,
            query: query,
            includeHidden: true
        )
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rows
        }
        return rows.filter { $0.category.axis == activeAxis }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Manage categories", table: "Vocabulary"))
                    .font(.headline)
                Spacer()
                Button {
                    creating = true
                } label: {
                    Label(String(localized: "New category", table: "Vocabulary"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "Search categories", table: "Vocabulary"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VocabularyCategoryAxisSwitchPill(selection: $activeAxis)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.02))

            List {
                ForEach(visibleRows) { row in
                    managerRow(row)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Done", table: "Vocabulary")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $creating) {
            VocabularyCategoryEditor(store: store, axis: activeAxis, preferredLanguages: languages)
        }
        .sheet(item: $editing) { category in
            VocabularyCategoryEditor(store: store, category: category, preferredLanguages: languages)
        }
        .confirmationDialog(
            String(localized: "Delete this category?", table: "Vocabulary"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(String(localized: "Delete category", table: "Vocabulary"), role: .destructive) {
                if let deleting {
                    let baseline = store.classification
                    var edited = baseline
                    do {
                        try VocabularyClassificationPolicy.removeCategory(deleting.id, from: &edited)
                        Task { _ = await store.updateClassification(edited, basedOn: baseline) }
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
                deleting = nil
            }
        }
    }

    private func managerRow(_ row: VocabularyClassificationProjection.Row) -> some View {
        let isExpanded = expanded.contains(row.id) || !query.isEmpty
        let tint = row.category.axis.tint
        let isVisible = !row.isHidden
        return HStack(spacing: 8) {
            Button {
                if !expanded.insert(row.id).inserted {
                    expanded.remove(row.id)
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 13, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(row.hasChildren ? 1 : 0)
            .disabled(!row.hasChildren)

            Image(systemName: row.depth == 0 ? row.symbolName : (row.hasChildren ? "folder" : "tag"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isVisible ? tint : Color.secondary.opacity(0.55))
                .frame(width: 15)

            Button {
                editing = row.category
            } label: {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 13, weight: row.depth == 0 ? .medium : .regular))
                        .foregroundStyle(isVisible ? .primary : .secondary)
                        .lineLimit(1)
                    if row.meaningCount > 0 {
                        Text("\(row.meaningCount)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1)
                            .background(Capsule(style: .continuous).fill(tint.opacity(0.11)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            Toggle(
                String(localized: "Visible", table: "Vocabulary"),
                isOn: Binding(
                    get: { !store.classification.overrides.contains { $0.categoryID == row.category.id && $0.isHidden } },
                    set: { visible in setVisible(visible, category: row.category) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                editing = row.category
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Edit category", table: "Vocabulary"))

            if row.category.frameworkID == nil {
                Button {
                    deleting = row.category
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.red.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Delete category", table: "Vocabulary"))
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 14)
        .padding(.vertical, 1.5)
    }

    private func setVisible(_ visible: Bool, category: VocabularyCategory) {
        let baseline = store.classification
        var edited = baseline
        if let position = edited.overrides.firstIndex(where: { $0.categoryID == category.id }) {
            edited.overrides[position].isHidden = !visible
        } else {
            edited.overrides.append(.init(categoryID: category.id, isHidden: !visible))
        }
        Task { _ = await store.updateClassification(edited, basedOn: baseline) }
    }
}
