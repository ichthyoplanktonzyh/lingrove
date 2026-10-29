import SwiftUI

/// Compact category filter and directory toggle bar anchored at the top of the "By meaning"
/// sidebar. Learners can see the active category breadcrumb at a glance, clear it in one click,
/// or expand the inline category directory tree without adding a third window column.
struct VocabularyCategoryFilterBar: View {
    @ObservedObject var store: VocabularyStore
    @Binding var selection: String
    @Binding var isDirectoryExpanded: Bool
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.vocabularyTextSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedCategory: VocabularyCategory? {
        guard let id = UUID(uuidString: selection) else { return nil }
        return store.classification.categories.first { $0.id == id && !$0.isRetired }
    }

    private var isFiltering: Bool {
        selection != "all"
    }

    private var activeTint: Color {
        if let selectedCategory {
            return selectedCategory.axis.tint
        }
        return selection == "uncategorized" ? .orange : LingroveBrand.accent
    }

    private var activeSymbol: String {
        if let selectedCategory {
            return VocabularyClassificationProjection.symbolName(for: selectedCategory, in: store.classification)
        }
        return selection == "uncategorized" ? "tray" : "square.grid.2x2"
    }

    private var activeTitle: String {
        if let selectedCategory {
            let trail = VocabularyClassificationProjection.breadcrumb(
                for: selectedCategory.id,
                in: store.classification,
                languages: languages
            )
            if !trail.isEmpty {
                return trail.suffix(2).joined(separator: " › ")
            }
            return VocabularyClassificationPolicy.title(selectedCategory, in: store.classification, languages: languages)
        }
        if selection == "uncategorized" {
            return String(localized: "Uncategorized meanings", table: "Vocabulary")
        }
        return String(localized: "All meanings", table: "Vocabulary")
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                    isDirectoryExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: activeSymbol)
                        .font(.system(size: textSize.size(10.5, sidebar: true), weight: .semibold))
                        .foregroundStyle(isFiltering ? activeTint : .secondary)
                    Text(activeTitle)
                        .font(textSize.font(12, weight: isFiltering ? .semibold : .medium, sidebar: true))
                        .foregroundStyle(isFiltering ? activeTint : .primary)
                        .lineLimit(1)
                    Image(systemName: isDirectoryExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(isFiltering ? activeTint.opacity(0.8) : Color.secondary.opacity(0.65))
                }
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isFiltering ? activeTint.opacity(0.12) : Color.primary.opacity(0.055))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isFiltering ? activeTint.opacity(0.28) : Color.primary.opacity(0.07), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Categories", table: "Vocabulary"))

            if isFiltering {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        selection = "all"
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear filters", table: "Vocabulary"))
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}

/// Collapsible category directory embedded inside the "By meaning" sidebar. Keeps the notebook
/// in a clean two-column split view while providing full hierarchical browsing, search, and
/// category management. Populated categories stand out with semantic icons and count badges,
/// while zero-count catalog categories recede visually until needed.
struct VocabularyCategorySidebar: View {
    @ObservedObject var store: VocabularyStore
    @Binding var selection: String
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var expanded: Set<String> = []
    @State private var query = ""
    @State private var creating = false
    @State private var editing: VocabularyCategory?
    @State private var managing = false
    @State private var showsAll = false

    private var rows: [VocabularyClassificationProjection.Row] {
        let values = VocabularyClassificationProjection.rows(
            store.classification,
            nodes: store.semantics.nodes,
            languages: languages,
            expanded: expanded,
            query: query
        )
        guard !showsAll, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return values }
        let revealed = UUID(uuidString: selection).map {
            VocabularyClassificationProjection.expansionPaths(for: [$0], in: store.classification)
        } ?? []
        return values.filter { $0.meaningCount > 0 || $0.category.id.uuidString == selection || revealed.contains($0.id) }
    }

    private var totalMeaningCount: Int {
        store.semantics.nodes.count
    }

    private var uncategorizedMeaningCount: Int {
        let categorized = Set(
            store.classification.memberships
                .filter { $0.provenance.status == .confirmed }
                .map(\.nodeID)
        )
        return store.semantics.nodes.filter { !categorized.contains($0.id) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            directoryToolbar
            List(selection: $selection) {
                overviewRow(
                    title: String(localized: "All meanings", table: "Vocabulary"),
                    symbol: "square.grid.2x2",
                    tag: "all",
                    count: totalMeaningCount,
                    tint: LingroveBrand.accent
                )
                overviewRow(
                    title: String(localized: "Uncategorized meanings", table: "Vocabulary"),
                    symbol: "tray",
                    tag: "uncategorized",
                    count: uncategorizedMeaningCount,
                    tint: .orange
                )
                ForEach(VocabularyCategory.Axis.allCases, id: \.self) { axis in
                    Section {
                        ForEach(rows.filter { $0.category.axis == axis }) { row in
                            categoryRow(row, axis: axis)
                        }
                    } header: {
                        HStack(spacing: 5) {
                            Image(systemName: axis.symbolName)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(axis.tint)
                            Text(axis.label)
                                .font(.system(size: textSize.size(11, sidebar: true), weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("vocabularyCategoryList")
        }
        .sheet(isPresented: $creating) {
            VocabularyCategoryEditor(
                store: store,
                parentID: UUID(uuidString: selection),
                preferredLanguages: languages
            ) { id in
                selection = id.uuidString
            }
        }
        .sheet(item: $editing) { category in
            VocabularyCategoryEditor(store: store, category: category, preferredLanguages: languages)
        }
        .sheet(isPresented: $managing) {
            VocabularyCategoryManager(store: store)
        }
        .onAppear {
            if let id = UUID(uuidString: selection) {
                reveal(id)
            }
        }
        .onChange(of: selection) { _, value in
            if let id = UUID(uuidString: value) {
                reveal(id)
            }
        }
        .onChange(of: store.classification) { _, index in
            guard let id = UUID(uuidString: selection) else { return }
            if !index.categories.contains(where: { $0.id == id && !$0.isRetired }) ||
                index.overrides.contains(where: { $0.categoryID == id && $0.isHidden }) {
                selection = "all"
            }
        }
    }

    private var directoryToolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search categories", table: "Vocabulary"), text: $query)
                    .textFieldStyle(.plain)
                    .font(textSize.font(12, sidebar: true))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear", table: "Vocabulary"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            Menu {
                Toggle(String(localized: "All categories", table: "Vocabulary"), isOn: $showsAll)
                Divider()
                Button(String(localized: "Manage categories", table: "Vocabulary")) { managing = true }
                Button(String(localized: "New category", table: "Vocabulary")) { creating = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(String(localized: "Manage categories", table: "Vocabulary"))
            .accessibilityIdentifier("vocabularyManageCategories")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }

    private func overviewRow(
        title: String,
        symbol: String,
        tag: String,
        count: Int,
        tint: Color
    ) -> some View {
        let isSelected = selection == tag
        return HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: textSize.size(11.5, sidebar: true), weight: .semibold))
                .foregroundStyle(isSelected ? tint : .secondary)
                .frame(width: 16)
            Text(title)
                .font(textSize.font(13, weight: isSelected ? .semibold : .medium, sidebar: true))
                .lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: textSize.size(10.5, sidebar: true), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? tint.opacity(0.14) : Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.vertical, 1.5)
        .tag(tag)
    }

    private func categoryRow(
        _ row: VocabularyClassificationProjection.Row,
        axis: VocabularyCategory.Axis
    ) -> some View {
        let hasItems = row.meaningCount > 0
        let isSelected = selection == row.category.id.uuidString
        let isExpanded = expanded.contains(row.id) || !query.isEmpty
        return HStack(spacing: 5) {
            Button {
                if !expanded.insert(row.id).inserted {
                    expanded.remove(row.id)
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hasItems ? .secondary : .tertiary)
                    .frame(width: 13, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(row.hasChildren ? 1 : 0)
            .disabled(!row.hasChildren)
            .accessibilityLabel(row.title)

            Image(systemName: row.depth == 0 ? row.symbolName : (row.hasChildren ? "folder" : "tag"))
                .font(.system(size: textSize.size(11, sidebar: true), weight: hasItems ? .semibold : .regular))
                .foregroundStyle(hasItems || isSelected ? axis.tint : Color.secondary.opacity(0.6))
                .frame(width: 15)

            Text(row.title)
                .font(textSize.font(12.5, weight: hasItems || isSelected ? .medium : .regular, sidebar: true))
                .foregroundStyle(hasItems || isSelected ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            if hasItems {
                Text("\(row.meaningCount)")
                    .font(.system(size: textSize.size(10, sidebar: true), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(axis.tint)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(axis.tint.opacity(0.12))
                    )
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 13)
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
        .tag(row.category.id.uuidString)
        .contextMenu {
            Button(String(localized: "Edit category", table: "Vocabulary")) {
                editing = row.category
            }
            Button(String(localized: "New category", table: "Vocabulary")) {
                selection = row.category.id.uuidString
                creating = true
            }
        }
    }

    private func reveal(_ id: UUID) {
        let paths = VocabularyClassificationProjection.expansionPaths(for: [id], in: store.classification)
        expanded.formUnion(paths)
    }
}

extension VocabularyCategory.Axis {
    var label: String {
        switch self {
        case .content: String(localized: "Content meanings", table: "Vocabulary")
        case .function: String(localized: "Communicative functions", table: "Vocabulary")
        }
    }

    var tint: Color {
        switch self {
        case .content: LingroveBrand.accent
        case .function: .teal
        }
    }

    var symbolName: String {
        switch self {
        case .content: "circle.hexagongrid"
        case .function: "bubble.left.and.bubble.right"
        }
    }
}

/// Compact two-segment capsule toggle for switching between Content and Communicative Function
/// category trees inside category sheets without overflowing AppKit's segmented control width.
struct VocabularyCategoryAxisSwitchPill: View {
    @Binding var selection: VocabularyCategory.Axis

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VocabularyCategory.Axis.allCases, id: \.self) { axis in
                let isSelected = selection == axis
                Button {
                    selection = axis
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: axis.symbolName)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(axis.label)
                            .font(.caption.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? axis.tint : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(axis.tint.opacity(0.14))
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .fixedSize()
    }
}
