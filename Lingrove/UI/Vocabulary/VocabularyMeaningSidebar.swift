import SwiftUI

/// Unified semantic outline sidebar for "By meaning" mode. Replaces the old split category drawer
/// and flat meaning list with a single hierarchical taxonomy tree:
/// `Axis (Content / Function) -> Category -> Subcategory -> Meaning Node`.
/// Learners can toggle `showsUnexplored` to reveal zero-count semantic categories alongside
/// their populated branches, answering both "where does this belong?" and "what haven't I learned yet?".
struct VocabularyMeaningSidebar: View {
    @ObservedObject var store: VocabularyStore
    let items: [VocabularyMeaningBrowserProjection.Item]
    let entries: [VocabularyEntry]
    let unclassified: [VocabularySelection]
    let query: String
    var isDetailed = false
    @Binding var showsUnexplored: Bool
    @Binding var destination: VocabularyMeaningDestination?
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var expanded: Set<String> = []
    @State private var isUncategorizedMeaningsExpanded = true
    @State private var isUnclassifiedExpanded = false
    @State private var creatingCategoryUnder: UUID?
    @State private var creatingRootCategory = false
    @State private var creatingMeaningUnder: UUID?
    @State private var editingCategory: VocabularyCategory?
    @State private var managingCategories = false
    @State private var didAutoExpand = false

    private var hasClassificationCatalog: Bool {
        store.classification.categories.contains { !$0.isRetired }
    }

    private var sidebarSelection: Binding<VocabularyMeaningDestination?> {
        Binding(get: {
            if let categoryID = destination?.categoryID { return .category(categoryID) }
            if let nodeID = destination?.nodeID { return .node(nodeID) }
            if case .unclassified = destination { return .unclassified }
            return destination?.senseID.map { .sense(nodeID: nil, senseID: $0) }
        }, set: { value in
            if let value { destination = value }
        })
    }

    private var revealedCategoryIDs: Set<UUID> {
        var ids = Set<UUID>()
        if let catID = destination?.categoryID {
            ids.insert(catID)
        }
        if let nodeID = destination?.nodeID {
            let memberCatIDs = store.classification.memberships
                .filter { $0.nodeID == nodeID && $0.provenance.status == .confirmed }
                .map(\.categoryID)
            ids.formUnion(memberCatIDs)
        }
        return ids
    }

    private var uncategorizedMeanings: [VocabularyMeaningBrowserProjection.Item] {
        guard hasClassificationCatalog else { return items }
        return VocabularyClassificationProjection.uncategorizedMeanings(
            classification: store.classification,
            items: items
        )
    }

    private func outlineRows(for axis: VocabularyCategory.Axis) -> [VocabularyClassificationProjection.OutlineRow] {
        VocabularyClassificationProjection.outlineRows(
            axis: axis,
            classification: store.classification,
            items: items,
            entries: entries,
            languages: languages,
            expanded: expanded,
            query: query,
            showsUnexplored: showsUnexplored,
            revealedCategoryIDs: revealedCategoryIDs
        )
    }

    private func expressionPreview(for item: VocabularyMeaningBrowserProjection.Item) -> String {
        var seen = Set<String>()
        let names = item.selections.compactMap { target -> String? in
            guard let expression = entries.first(where: { $0.id == target.entryID })?.expression else { return nil }
            return seen.insert(expression).inserted ? expression : nil
        }
        if !names.isEmpty {
            return names.joined(separator: " · ")
        }
        return item.node.definition
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasClassificationCatalog {
                taxonomyStatusBar
            }
            List(selection: sidebarSelection) {
                if hasClassificationCatalog {
                    ForEach(VocabularyCategory.Axis.allCases, id: \.self) { axis in
                        let rows = outlineRows(for: axis)
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { row in
                                    outlineRowView(row)
                                }
                            } header: {
                                axisSectionHeader(axis)
                            }
                        }
                    }

                    if !uncategorizedMeanings.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $isUncategorizedMeaningsExpanded) {
                                ForEach(uncategorizedMeanings) { item in
                                    meaningItemRow(item, indent: 0)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "questionmark.folder")
                                        .font(.system(size: textSize.size(11, sidebar: true), weight: .semibold))
                                        .foregroundStyle(.orange)
                                    Text(String(localized: "Uncategorized meanings", table: "Vocabulary"))
                                        .font(textSize.font(13, weight: .medium, sidebar: true))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(uncategorizedMeanings.count)")
                                        .font(.system(size: textSize.size(10.5, sidebar: true), weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.12), in: Capsule(style: .continuous))
                                }
                            }
                        }
                    }
                } else {
                    ForEach(items) { item in
                        meaningItemRow(item, indent: 0)
                    }
                }

                if !unclassified.isEmpty {
                    unclassifiedSection
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("vocabularyMeaningList")
        }
        .onAppear {
            autoExpandInitialPopulatedPathsIfNeeded()
            revealDestination(destination)
        }
        .onChange(of: store.classification) { _, _ in
            autoExpandInitialPopulatedPathsIfNeeded()
        }
        .onChange(of: destination, initial: true) { _, next in
            revealDestination(next)
        }
        .sheet(isPresented: $creatingRootCategory) {
            VocabularyCategoryEditor(store: store, preferredLanguages: languages) { id in
                destination = .category(id)
            }
        }
        .sheet(isPresented: Binding(get: { creatingCategoryUnder != nil }, set: { if !$0 { creatingCategoryUnder = nil } })) {
            if let parentID = creatingCategoryUnder {
                VocabularyCategoryEditor(store: store, parentID: parentID, preferredLanguages: languages) { id in
                    destination = .category(id)
                }
            }
        }
        .sheet(isPresented: Binding(get: { creatingMeaningUnder != nil }, set: { if !$0 { creatingMeaningUnder = nil } })) {
            if let catID = creatingMeaningUnder {
                VocabularyMeaningEditor(store: store, categoryID: catID, preferredLanguages: languages) { id in
                    destination = .node(id)
                }
            }
        }
        .sheet(item: $editingCategory) { category in
            VocabularyCategoryEditor(store: store, category: category, preferredLanguages: languages)
        }
        .sheet(isPresented: $managingCategories) {
            VocabularyCategoryManager(store: store)
        }
    }

    /// Compact bar below the filter strip allowing learners to toggle unexplored (0-meaning)
    /// semantic domains and manage the taxonomy tree.
    private var taxonomyStatusBar: some View {
        HStack(spacing: 6) {
            Button {
                showsUnexplored.toggle()
            } label: {
                HStack(spacing: 4.5) {
                    Image(systemName: showsUnexplored ? "eye.fill" : "eye.slash")
                        .font(.system(size: textSize.size(10, sidebar: true), weight: .semibold))
                    Text(String(localized: "Show unexplored categories", table: "Vocabulary"))
                        .font(textSize.font(11.5, weight: showsUnexplored ? .semibold : .medium, sidebar: true))
                        .lineLimit(1)
                }
                .foregroundStyle(showsUnexplored ? LingroveBrand.accent : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(showsUnexplored ? LingroveBrand.accent.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(showsUnexplored ? LingroveBrand.accent.opacity(0.26) : Color.primary.opacity(0.07), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show unexplored categories", table: "Vocabulary"))
            .accessibilityIdentifier("vocabularyToggleUnexplored")

            Spacer(minLength: 4)

            Menu {
                Toggle(String(localized: "Show unexplored categories", table: "Vocabulary"), isOn: $showsUnexplored)
                Divider()
                Button(String(localized: "Expand all populated", table: "Vocabulary")) {
                    expandAllPopulatedPaths()
                }
                Button(String(localized: "Collapse all", table: "Vocabulary")) {
                    expanded.removeAll()
                }
                Divider()
                Button(String(localized: "New category", table: "Vocabulary")) { creatingRootCategory = true }
                Button(String(localized: "Manage categories", table: "Vocabulary")) { managingCategories = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Manage categories", table: "Vocabulary"))
            .accessibilityIdentifier("vocabularyManageCategories")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5.5)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }

    private func axisSectionHeader(_ axis: VocabularyCategory.Axis) -> some View {
        let coverage = VocabularyClassificationProjection.axisCoverage(
            axis: axis,
            classification: store.classification,
            nodes: items.map(\.node)
        )
        return HStack(spacing: 5) {
            Image(systemName: axis.symbolName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(axis.tint)
            Text(axis.label)
                .font(.system(size: textSize.size(11, sidebar: true), weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if coverage.total > 0 {
                Text("\(coverage.explored)/\(coverage.total)")
                    .font(.system(size: textSize.size(10, sidebar: true), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "Explored domains", table: "Vocabulary"))
            }
        }
    }

    @ViewBuilder
    private func outlineRowView(_ row: VocabularyClassificationProjection.OutlineRow) -> some View {
        switch row.target {
        case .category(let category):
            categoryOutlineRow(row, category: category)
        case .meaning(let item, _):
            meaningItemRow(item, indent: CGFloat(min(row.depth, 8)) * 13)
        }
    }

    private func categoryOutlineRow(
        _ row: VocabularyClassificationProjection.OutlineRow,
        category: VocabularyCategory
    ) -> some View {
        let hasItems = row.itemCount > 0
        let isSelected = destination == .category(category.id)
        let isExpanded = expanded.contains(row.id) || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tint = row.axis.tint

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

            Image(systemName: hasItems ? row.symbolName : (row.depth == 0 ? row.symbolName : "circle.dashed"))
                .font(.system(size: textSize.size(11, sidebar: true), weight: hasItems ? .semibold : .regular))
                .foregroundStyle(hasItems || isSelected ? tint : Color.secondary.opacity(0.55))
                .frame(width: 15)

            Text(row.title)
                .font(textSize.font(13, weight: hasItems || isSelected ? .medium : .regular, sidebar: true))
                .foregroundStyle(hasItems || isSelected ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if hasItems {
                Text("\(row.itemCount)")
                    .font(.system(size: textSize.size(10, sidebar: true), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.11))
                    )
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 13)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(VocabularyMeaningDestination.category(category.id))
        .contextMenu {
            Button(String(localized: "New meaning", table: "Vocabulary")) {
                creatingMeaningUnder = category.id
            }
            Divider()
            Button(String(localized: "Edit category", table: "Vocabulary")) {
                editingCategory = category
            }
            Button(String(localized: "New category", table: "Vocabulary")) {
                creatingCategoryUnder = category.id
            }
        }
    }

    private func meaningItemRow(_ item: VocabularyMeaningBrowserProjection.Item, indent: CGFloat) -> some View {
        let isSelected = destination?.nodeID == item.id
        let preview = expressionPreview(for: item)
        let tint: Color = item.node.kind == .concept ? LingroveBrand.accent : .teal
        return VStack(alignment: .leading, spacing: 2.5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.node.kind.symbolName)
                    .font(.system(size: textSize.size(10.5, sidebar: true), weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(item.title)
                    .font(textSize.font(13.5, weight: .semibold, sidebar: true))
                    .lineLimit(1)
                if !isDetailed && isSelected && !preview.isEmpty {
                    Text(preview)
                        .font(textSize.font(12, sidebar: true))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                if item.pendingCount > 0 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help(String(localized: "Suggested grouping", table: "Vocabulary"))
                }
                Text("\(item.selections.count)")
                    .font(.system(size: textSize.size(10, sidebar: true), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(item.selections.isEmpty ? Color.secondary : tint)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(item.selections.isEmpty ? Color.primary.opacity(0.06) : tint.opacity(0.12))
                    )
            }
            if isDetailed && !preview.isEmpty {
                Text(preview)
                    .font(textSize.font(12.5, sidebar: true))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
        }
        .padding(.leading, indent + (indent > 0 ? 18 : 0))
        .padding(.vertical, isDetailed ? 3.5 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .tag(VocabularyMeaningDestination.node(item.id))
    }

    private var unclassifiedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isUnclassifiedExpanded) {
                ForEach(unclassified, id: \.senseID) { target in
                    if let entry = entries.first(where: { $0.id == target.entryID }),
                       let sense = entry.senses.first(where: { $0.id == target.senseID }) {
                        let isSenseSelected = destination?.nodeID == nil && destination?.senseID == sense.id
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(entry.expression)
                                    .font(textSize.font(13.5, weight: .semibold, sidebar: true))
                                    .lineLimit(1)
                                if !isDetailed && isSenseSelected && !sense.displayTitle.isEmpty {
                                    Text(sense.displayTitle)
                                        .font(textSize.font(12, sidebar: true))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                VocabularyExpressionLanguageBadge(language: entry.language)
                            }
                            if isDetailed && !sense.displayTitle.isEmpty {
                                Text(sense.displayTitle)
                                    .font(textSize.font(12.5, sidebar: true))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tag(VocabularyMeaningDestination.sense(nodeID: nil, senseID: sense.id))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: textSize.size(11.5, sidebar: true), weight: .semibold))
                        .foregroundStyle(destination == .unclassified ? LingroveBrand.accent : .secondary)
                    Text(String(localized: "Other expressions", table: "Vocabulary"))
                        .font(textSize.font(13.5, weight: .medium, sidebar: true))
                        .foregroundStyle(destination == .unclassified ? LingroveBrand.accent : .primary)
                    Spacer()
                    Text("\(unclassified.count)")
                        .font(.system(size: textSize.size(10.5, sidebar: true), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    destination = .unclassified
                    if !isUnclassifiedExpanded {
                        isUnclassifiedExpanded = true
                    }
                }
            }
        }
    }

    private func autoExpandInitialPopulatedPathsIfNeeded() {
        guard !didAutoExpand, hasClassificationCatalog else { return }
        didAutoExpand = true
        expandAllPopulatedPaths()
    }

    private func expandAllPopulatedPaths() {
        let populatedCategoryIDs = Set(
            store.classification.memberships
                .filter { $0.provenance.status == .confirmed }
                .map(\.categoryID)
        )
        guard !populatedCategoryIDs.isEmpty else { return }
        var paths = VocabularyClassificationProjection.expansionPaths(
            for: populatedCategoryIDs,
            in: store.classification
        )
        // Also expand the leaf category itself so its direct meaning nodes are immediately visible.
        let parents = Dictionary(grouping: store.classification.parents, by: \.categoryID)
        for catID in populatedCategoryIDs {
            var chain = [catID], seen: Set<UUID> = [catID]
            while let current = chain.last,
                  let parent = parents[current]?.first?.parentID,
                  seen.insert(parent).inserted {
                chain.append(parent)
            }
            let fullKey = "/" + chain.reversed().map(\.uuidString).joined(separator: "/")
            paths.insert(fullKey)
        }
        expanded.formUnion(paths)
    }

    private func revealDestination(_ next: VocabularyMeaningDestination?) {
        guard let next else { return }
        switch next {
        case .unclassified, .sense(nodeID: nil, senseID: _):
            isUnclassifiedExpanded = true
        case .category(let catID):
            let paths = VocabularyClassificationProjection.expansionPaths(
                for: [catID],
                in: store.classification
            )
            expanded.formUnion(paths)
        case .node(let nodeID), .sense(nodeID: let nodeID?, senseID: _):
            let catIDs = Set(
                store.classification.memberships
                    .filter { $0.nodeID == nodeID && $0.provenance.status == .confirmed }
                    .map(\.categoryID)
            )
            if catIDs.isEmpty {
                isUncategorizedMeaningsExpanded = true
            } else {
                var paths = VocabularyClassificationProjection.expansionPaths(
                    for: catIDs,
                    in: store.classification
                )
                let parents = Dictionary(grouping: store.classification.parents, by: \.categoryID)
                for catID in catIDs {
                    var chain = [catID], seen: Set<UUID> = [catID]
                    while let current = chain.last,
                          let parent = parents[current]?.first?.parentID,
                          seen.insert(parent).inserted {
                        chain.append(parent)
                    }
                    paths.insert("/" + chain.reversed().map(\.uuidString).joined(separator: "/"))
                }
                expanded.formUnion(paths)
            }
        }
    }
}
