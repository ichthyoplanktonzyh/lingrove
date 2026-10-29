import SwiftUI

/// An additive column beside the existing meaning list. The notebook owns the selected filter;
/// this view owns only category disclosure/search state and never changes lexical navigation.
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

    private var rows: [VocabularyClassificationProjection.Row] {
        VocabularyClassificationProjection.rows(store.classification, nodes: store.semantics.nodes,
            languages: languages, expanded: expanded, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Categories", table: "Vocabulary")).font(.headline)
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus") }
                    .help(String(localized: "New category", table: "Vocabulary"))
                    .accessibilityIdentifier("vocabularyNewCategory")
                Button { managing = true } label: { Image(systemName: "ellipsis") }
                    .help(String(localized: "Manage categories", table: "Vocabulary"))
                    .accessibilityIdentifier("vocabularyManageCategories")
            }
            .buttonStyle(.borderless)
            .padding(12)
            TextField(String(localized: "Search categories", table: "Vocabulary"), text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            List(selection: $selection) {
                Label(String(localized: "All meanings", table: "Vocabulary"), systemImage: "square.grid.2x2")
                    .tag("all")
                Label(String(localized: "Uncategorized meanings", table: "Vocabulary"), systemImage: "tray")
                    .tag("uncategorized")
                ForEach(VocabularyCategory.Axis.allCases, id: \.self) { axis in
                    Section(axis.label) {
                        ForEach(rows.filter { $0.category.axis == axis }) { row in
                            HStack(spacing: 5) {
                                Button {
                                    if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                                } label: {
                                    Image(systemName: expanded.contains(row.id) || !query.isEmpty ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold)).frame(width: 12, height: 18)
                                }
                                .buttonStyle(.plain).opacity(row.hasChildren ? 1 : 0)
                                .disabled(!row.hasChildren)
                                .accessibilityLabel(row.title)
                                Text(row.title).lineLimit(1)
                                Spacer(minLength: 2)
                                if row.meaningCount > 0 {
                                    Text("\(row.meaningCount)").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .font(textSize.font(12.5, sidebar: true))
                            .padding(.leading, CGFloat(min(row.depth, 8)) * 12)
                            .accessibilityElement(children: .contain)
                            .tag(row.category.id.uuidString)
                            .contextMenu {
                                Button(String(localized: "Edit category", table: "Vocabulary")) { editing = row.category }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("vocabularyCategoryList")
        }
        .sheet(isPresented: $creating) {
            VocabularyCategoryEditor(store: store, parentID: UUID(uuidString: selection), preferredLanguages: languages) { id in
                selection = id.uuidString
            }
        }
        .sheet(item: $editing) { category in VocabularyCategoryEditor(store: store, category: category, preferredLanguages: languages) }
        .sheet(isPresented: $managing) { VocabularyCategoryManager(store: store) }
        .onChange(of: selection) { _, value in
            if let id = UUID(uuidString: value) { reveal(id) }
        }
        .onChange(of: store.classification) { _, index in
            guard let id = UUID(uuidString: selection) else { return }
            if !index.categories.contains(where: { $0.id == id && !$0.isRetired }) ||
                index.overrides.contains(where: { $0.categoryID == id && $0.isHidden }) { selection = "all" }
        }
    }

    private func reveal(_ id: UUID) {
        let hidden = Set(store.classification.overrides.filter(\.isHidden).map(\.categoryID))
        let visible = Set(store.classification.categories.filter { !$0.isRetired && !hidden.contains($0.id) }.map(\.id))
        let parents = Dictionary(grouping: store.classification.parents.filter { visible.contains($0.parentID) }, by: \.categoryID)
        var path = [id], seen: Set<UUID> = [id]
        while let child = path.last, let parent = parents[child]?.first?.parentID, seen.insert(parent).inserted { path.append(parent) }
        var key = ""
        for ancestor in path.reversed().dropLast() { key += "/" + ancestor.uuidString; expanded.insert(key) }
    }
}

extension VocabularyCategory.Axis {
    var label: String {
        switch self {
        case .content: String(localized: "Content meanings", table: "Vocabulary")
        case .function: String(localized: "Communicative functions", table: "Vocabulary")
        }
    }
}
