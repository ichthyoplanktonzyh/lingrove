import SwiftUI

/// Inline category breadcrumb bar integrated into `VocabularyMeaningDetail`'s editorial header.
/// Shows hierarchical category pills ("Time and progression › Timing") when categorized, or a
/// quiet dashed-border prompt when uncategorized, eliminating the old full-width blank row.
struct VocabularyMeaningCategoryControl: View {
    @ObservedObject var store: VocabularyStore
    let nodeID: UUID
    var selectCategory: ((UUID) -> Void)?
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var editing = false

    private var categories: [VocabularyCategory] {
        let ids = Set(
            store.classification.memberships
                .filter { $0.nodeID == nodeID && $0.provenance.status == .confirmed }
                .map(\.categoryID)
        )
        return store.classification.categories.filter { ids.contains($0.id) && !$0.isRetired }
    }

    var body: some View {
        Group {
            if categories.isEmpty {
                Button {
                    editing = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: textSize.size(11), weight: .semibold))
                        Text(String(localized: "Categorize", table: "Vocabulary"))
                            .font(textSize.font(12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(0.15),
                                style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])
                            )
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vocabularyCategorizeMeaning")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categories) { category in
                            categoryBreadcrumbPill(category)
                        }
                        Button {
                            editing = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.gearshape")
                                    .font(.system(size: textSize.size(10.5), weight: .semibold))
                                Text(String(localized: "Categorize", table: "Vocabulary"))
                                    .font(textSize.font(11.5, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8.5)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.055))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                            )
                            .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("vocabularyCategorizeMeaning")
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            VocabularyMeaningCategorySheet(store: store, nodeID: nodeID)
        }
    }

    private func categoryBreadcrumbPill(_ category: VocabularyCategory) -> some View {
        let trail = VocabularyClassificationProjection.breadcrumb(
            for: category.id,
            in: store.classification,
            languages: languages
        )
        let displayPath = trail.isEmpty
            ? VocabularyClassificationPolicy.title(category, in: store.classification, languages: languages)
            : trail.suffix(2).joined(separator: " › ")
        let icon = VocabularyClassificationProjection.symbolName(for: category, in: store.classification)
        let tint = category.axis.tint

        return Button {
            if let selectCategory {
                selectCategory(category.id)
            } else {
                editing = true
            }
        } label: {
            HStack(spacing: 4.5) {
                Image(systemName: icon)
                    .font(.system(size: textSize.size(10), weight: .semibold))
                Text(displayPath)
                    .font(textSize.font(11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8.5)
            .padding(.vertical, 3.5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.11))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.24), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Hierarchical category membership picker for a single meaning node. Replaces the old flat
/// 256-checkbox form with a collapsible domain tree, active selection chips, and axis filtering
/// while preserving conflict-checked baseline commits.
struct VocabularyMeaningCategorySheet: View {
    @ObservedObject var store: VocabularyStore
    private let node: VocabularyMeaningNode
    private let originalIndex: VocabularyClassificationIndex
    private let onSaveDraft: ((VocabularyClassificationIndex, Set<UUID>) -> Void)?
    private var nodeID: UUID { node.id }
    @State private var baseline: VocabularyClassificationIndex
    @State private var selectedIDs: Set<UUID>
    @State private var expanded: Set<String>
    @State private var activeAxis: VocabularyCategory.Axis = .content
    @State private var query = ""
    @State private var creating = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, nodeID: UUID) {
        let node = store.semantics.nodes.first { $0.id == nodeID } ?? .init(id: nodeID, labels: [])
        self.init(store: store, node: node, index: store.classification,
            selection: Set(store.classification.memberships.filter { $0.nodeID == nodeID }.map(\.categoryID)),
            axis: node.kind == .function ? .function : .content, onSave: nil)
    }

    /// A parent editor can borrow the picker without publishing any intermediate directory edits.
    init(store: VocabularyStore, node: VocabularyMeaningNode, index: VocabularyClassificationIndex,
         selection: Set<UUID>, axis: VocabularyCategory.Axis,
         onSave: ((VocabularyClassificationIndex, Set<UUID>) -> Void)?) {
        self.store = store; self.node = node; originalIndex = index; onSaveDraft = onSave
        _baseline = State(initialValue: index); _selectedIDs = State(initialValue: selection)
        _expanded = State(initialValue: VocabularyClassificationProjection.expansionPaths(
            for: selection, in: index, includeHidden: true))
        _activeAxis = State(initialValue: axis)
    }

    private var selectedCategories: [VocabularyCategory] {
        baseline.categories.filter { selectedIDs.contains($0.id) }
    }

    private var visibleRows: [VocabularyClassificationProjection.Row] {
        let allRows = VocabularyClassificationProjection.rows(
            baseline,
            nodes: store.semantics.nodes,
            languages: languages,
            expanded: expanded,
            query: query,
            includeHidden: true
        )
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return allRows
        }
        return allRows.filter { $0.category.axis == activeAxis }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            if !selectedCategories.isEmpty {
                selectedChipsStrip
            }
            Divider()
            filterToolbar
            treeList
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            Divider()
            sheetFooter
        }
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(saving)
        .sheet(isPresented: $creating) {
            VocabularyCategoryEditor(store: store, parentID: selectedIDs.count == 1 ? selectedIDs.first : nil,
                axis: activeAxis, draft: baseline, preferredLanguages: languages, onDraftSaved: { index, id in
                    baseline = index; selectedIDs.insert(id)
                    if let category = index.categories.first(where: { $0.id == id }) { activeAxis = category.axis }
                    expanded.formUnion(VocabularyClassificationProjection.expansionPaths(
                        for: selectedIDs, in: baseline, includeHidden: true))
                })
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Categorize", table: "Vocabulary"))
                    .font(.headline)
                if !node.title(in: languages).isEmpty {
                    Text(node.title(in: languages))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button(String(localized: "New category", table: "Vocabulary")) { creating = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("vocabularyCategoryActions")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var selectedChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedCategories) { category in
                    let trail = VocabularyClassificationProjection.breadcrumb(
                        for: category.id,
                        in: baseline,
                        languages: languages
                    )
                    let labelText = trail.isEmpty ? title(category) : trail.suffix(2).joined(separator: " › ")
                    let tint = category.axis.tint
                    Button {
                        selectedIDs.remove(category.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: VocabularyClassificationProjection.symbolName(for: category, in: baseline))
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(labelText)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .opacity(0.75)
                        }
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(tint.opacity(0.12))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private var filterToolbar: some View {
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
    }

    private var treeList: some View {
        List {
            ForEach(visibleRows) { row in
                categoryPickerRow(row)
            }
        }
        .listStyle(.inset)
        .disabled(saving)
    }

    private func categoryPickerRow(_ row: VocabularyClassificationProjection.Row) -> some View {
        let isSelected = selectedIDs.contains(row.category.id)
        let isExpanded = expanded.contains(row.id) || !query.isEmpty
        let tint = row.category.axis.tint
        let parentTrail = row.breadcrumb.dropLast().joined(separator: " › ")

        return HStack(spacing: 7) {
            Button {
                if !expanded.insert(row.id).inserted {
                    expanded.remove(row.id)
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(row.hasChildren ? 1 : 0)
            .disabled(!row.hasChildren)

            Toggle(isOn: Binding(
                get: { selectedIDs.contains(row.category.id) },
                set: { checked in
                    if checked {
                        selectedIDs.insert(row.category.id)
                    } else {
                        selectedIDs.remove(row.category.id)
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: row.depth == 0 ? row.symbolName : (row.hasChildren ? "folder" : "tag"))
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? tint : .secondary)
                        .frame(width: 15)
                    Text(row.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !query.isEmpty && !parentTrail.isEmpty {
                        Text(parentTrail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 4)

            if row.meaningCount > 0 {
                Text("\(row.meaningCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 15)
        .padding(.vertical, 1.5)
    }

    private var sheetFooter: some View {
        HStack {
            if !selectedIDs.isEmpty {
                Text("\(selectedIDs.count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(LingroveBrand.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LingroveBrand.accent.opacity(0.12))
                    )
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
                .disabled(saving)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func title(_ category: VocabularyCategory) -> String {
        VocabularyClassificationPolicy.title(category, in: baseline, languages: languages)
    }

    private func save() {
        if let onSaveDraft { onSaveDraft(baseline, selectedIDs); dismiss(); return }
        var edited = baseline
        VocabularyClassificationPolicy.assign(nodeID: nodeID, categories: selectedIDs, in: &edited)
        saving = true
        Task {
            if await store.updateClassification(edited, basedOn: originalIndex) {
                dismiss()
            } else {
                failure = store.errorMessage
            }
            saving = false
        }
    }
}
