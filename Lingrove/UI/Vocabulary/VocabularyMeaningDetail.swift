import SwiftUI

/// A meaning page puts expression choices, their differences and original examples first.
/// It reads the same store as the notebook; optional organization never owns a second copy.
struct VocabularyMeaningDetail: View {
    @ObservedObject var store: VocabularyStore
    let node: VocabularyMeaningNode
    let entries: [VocabularyEntry]
    var speech: LearningSpeechController?
    let openSense: (VocabularySelection) -> Void
    let openMeaning: (UUID) -> Void
    var selectCategory: ((UUID) -> Void)?
    @Environment(\.vocabularyMeaningLanguages) private var meaningLanguages
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var editing = false
    @State private var associating = false
    @State private var editingMapping: VocabularyMeaningMapping?
    @State private var deleting = false

    private var mappings: [VocabularyMeaningMapping] { store.semantics.mappings.filter { $0.nodeID == node.id } }
    private var visibleEntries: [VocabularyEntry] {
        let ids = Set(mappings.map(\.senseID))
        return entries.compactMap { entry in
            var entry = entry; entry.senses.removeAll { !ids.contains($0.id) }
            return entry.senses.isEmpty ? nil : entry
        }
    }
    private var visibleSenseCount: Int {
        visibleEntries.reduce(0) { $0 + $1.senses.count }
    }
    private var cues: [VocabularyRetrievalCue] {
        let ids = Set(store.semantics.cueTargets.filter {
            $0.nodeID == node.id && $0.provenance.status == .confirmed
        }.map(\.cueID))
        return store.semantics.cues.filter { ids.contains($0.id) }
    }
    private var primaryTitle: String {
        node.title(in: meaningLanguages)
    }
    private var alternateLabels: [VocabularyMeaningLabel] {
        var seen: Set<String> = [primaryTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        return node.labels.filter { label in
            let trimmed = label.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed.lowercased()).inserted
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                meaningHeader
                expressionsSection
                relatedMeanings
                detailsSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $editing) {
            VocabularyMeaningEditor(store: store, node: node, preferredLanguages: meaningLanguages)
        }
        .sheet(isPresented: $associating) { VocabularyMeaningMappingEditor(store: store, nodeID: node.id) }
        .sheet(item: $editingMapping) { VocabularyMeaningMappingEditor(store: store, mapping: $0) }
        .confirmationDialog(String(localized: "Delete this meaning? Collected expressions will be kept.", table: "Vocabulary"),
            isPresented: $deleting) {
                Button(String(localized: "Delete meaning", table: "Vocabulary"), role: .destructive) {
                    let baseline = store.semantics; var edited = baseline
                    VocabularySemanticPolicy.removeNode(node.id, from: &edited)
                    Task { _ = await store.updateSemantics(edited, basedOn: baseline) }
                }
            }
    }

    private var meaningHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(primaryTitle)
                    .font(textSize.font(28, weight: .bold))
                    .tracking(-0.3)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    editing = true
                } label: {
                    Label(String(localized: "Edit", table: "Vocabulary"), systemImage: "pencil")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Menu {
                    Button(String(localized: "Edit", table: "Vocabulary")) { editing = true }
                    Divider()
                    Button(String(localized: "Delete meaning", table: "Vocabulary"), role: .destructive) { deleting = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    VocabularyMeaningKindBadge(kind: node.kind)
                        .fixedSize()
                    if node.provenance.status == .proposed {
                        Text(String(localized: "Suggested grouping", table: "Vocabulary"))
                            .font(textSize.font(11.5, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.11), in: Capsule(style: .continuous))
                            .fixedSize()
                    }
                    ForEach(alternateLabels.prefix(4)) { label in
                        HStack(spacing: 4) {
                            if let lang = label.language {
                                Text(lang.compactLabel)
                                    .font(textSize.font(10, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                            Text(label.text)
                                .font(textSize.font(12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                        .fixedSize()
                    }
                }
            }

            if !node.definition.isEmpty {
                Text(node.definition)
                    .font(textSize.font(18, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }

            if !node.scopeNote.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(textSize.font(12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(node.scopeNote)
                        .font(textSize.font(14))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VocabularyMeaningCategoryControl(
                store: store,
                nodeID: node.id,
                selectCategory: selectCategory
            )
            .padding(.top, 2)
        }
    }

    private var expressionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(String(localized: "My expressions", table: "Vocabulary"))
                    .font(textSize.font(15, weight: .semibold))
                if visibleSenseCount > 0 {
                    Text("\(visibleSenseCount)")
                        .font(textSize.font(11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(LingroveBrand.accent)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(LingroveBrand.accent.opacity(0.11), in: Capsule(style: .continuous))
                }
                Spacer()
                Button {
                    associating = true
                } label: {
                    Label(String(localized: "Add from vocabulary", table: "Vocabulary"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(store.entries.isEmpty)
            }

            if visibleEntries.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "text.book.closed")
                        .font(textSize.font(14))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "No matching expressions", table: "Vocabulary"))
                        .font(textSize.font(14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
                )
            } else {
                ForEach(visibleEntries) { entry in
                    ForEach(entry.senses) { sense in
                        expressionCard(entry, sense: sense)
                    }
                }
            }
        }
    }

    private func expressionCard(_ entry: VocabularyEntry, sense: VocabularySense) -> some View {
        let senseMappings = mappings.filter { $0.senseID == sense.id }
        let singleMapping = senseMappings.count == 1 ? senseMappings[0] : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    openSense(.init(entryID: entry.id, senseID: sense.id))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.expression)
                                .font(textSize.font(17.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            if entry.kind != .word {
                                Text(entry.kind.label)
                                    .font(textSize.font(11.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if !sense.displayTitle.isEmpty {
                            Text(sense.displayTitle)
                                .font(textSize.font(14.5))
                                .lineSpacing(2.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    if let speech {
                        LearningSpeechButton(
                            speech: speech,
                            request: SpeechRequest(
                                target: SpeechTarget(ownerID: node.id, itemID: "meaning.expression." + sense.id.uuidString),
                                text: entry.expression,
                                language: entry.language
                            ),
                            playLabel: String(localized: "Read aloud", table: "Vocabulary"),
                            stopLabel: String(localized: "Stop reading", table: "Vocabulary")
                        )
                    }
                    VocabularyExpressionLanguageBadge(language: entry.language)
                    if let singleMapping, singleMapping.provenance.status != .proposed {
                        Menu {
                            Button(String(localized: "Change", table: "Learning")) { editingMapping = singleMapping }
                            Divider()
                            Button(String(localized: "Remove from this group", table: "Vocabulary"), role: .destructive) {
                                removeMapping(singleMapping)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 20)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Button {
                        openSense(.init(entryID: entry.id, senseID: sense.id))
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(senseMappings) { mapping in
                if mappingShowsSummary(mapping, sense: sense, isSingle: singleMapping != nil) {
                    VocabularyMeaningMappingSummary(
                        store: store,
                        mapping: mapping,
                        sense: sense,
                        showsActionsMenu: singleMapping == nil || mapping.provenance.status == .proposed,
                        edit: { editingMapping = mapping }
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
        )
    }

    private func mappingShowsSummary(_ mapping: VocabularyMeaningMapping, sense: VocabularySense, isSingle: Bool) -> Bool {
        if !isSingle || mapping.provenance.status == .proposed { return true }
        let hasPattern = store.semantics.patterns.contains { $0.id == mapping.patternID }
        let hasExample = VocabularySemanticEditingPolicy.example(for: mapping, sense: sense) != nil
        return hasPattern || !mapping.nuance.isEmpty || !mapping.conditions.isEmpty ||
            hasExample || !mapping.provenance.source.isEmpty
    }

    private func removeMapping(_ mapping: VocabularyMeaningMapping) {
        let baseline = store.semantics; var edited = baseline
        edited.mappings.removeAll { $0.id == mapping.id }
        Task { _ = await store.updateSemantics(edited, basedOn: baseline) }
    }

    @ViewBuilder
    private var relatedMeanings: some View {
        // The graph and detail both show established relations. Proposed relations remain
        // available to maintenance tools, but cannot appear here as unqualified facts.
        let relations = VocabularyMeaningBrowserProjection.confirmedRelations(in: store.semantics).filter {
            $0.sourceID == node.id || $0.targetID == node.id
        }
        if !relations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Related meanings", table: "Vocabulary"))
                    .font(textSize.font(15, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(relations) { relation in
                        let outgoing = relation.sourceID == node.id
                        if let target = store.semantics.nodes.first(where: {
                            $0.id == (outgoing ? relation.targetID : relation.sourceID)
                        }) {
                            Button {
                                openMeaning(target.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(relation.kind == .narrower && !outgoing
                                         ? String(localized: "More general than", table: "Vocabulary") : relation.kind.label)
                                        .font(textSize.font(11.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                                    Text(target.title(in: meaningLanguages))
                                        .font(textSize.font(14.5, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(textSize.font(11.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        if !cues.isEmpty || !node.provenance.source.isEmpty || !node.roles.isEmpty {
            DisclosureGroup(String(localized: "Details", table: "Learning")) {
                VStack(alignment: .leading, spacing: 8) {
                    if !cues.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: textSize.size(11), weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(cues.map(\.text).joined(separator: " · "))
                                .font(textSize.font(13))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if !node.roles.isEmpty {
                        ForEach(node.roles) { role in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("[\(role.name)]")
                                    .font(textSize.font(12.5, weight: .semibold))
                                    .foregroundStyle(LingroveBrand.accent)
                                if !role.description.isEmpty {
                                    Text(role.description)
                                        .font(textSize.font(13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !node.provenance.source.isEmpty {
                        Text(node.provenance.source)
                            .font(textSize.font(12.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 6)
            }
            .font(textSize.font(12.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

/// Dedicated triage surface shown when the learner selects "Other expressions" in the meaning
/// sidebar or graph filter bar. Allows reviewing ungrouped senses and assigning each to an
/// existing or newly created meaning node in place.
struct VocabularyUnclassifiedDetail: View {
    @ObservedObject var store: VocabularyStore
    let entries: [VocabularyEntry]
    let unclassified: [VocabularySelection]
    var speech: LearningSpeechController?
    let openSense: (VocabularySelection) -> Void
    let openMeaning: (UUID) -> Void
    @Environment(\.vocabularyMeaningLanguages) private var meaningLanguages
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var groupingSenseID: UUID?
    @State private var creatingMeaningFor: VocabularySelection?
    @State private var creatingBlankMeaning = false

    private struct ResolvedItem: Identifiable {
        let selection: VocabularySelection
        let entry: VocabularyEntry
        let sense: VocabularySense
        var id: UUID { sense.id }
    }

    private var resolvedItems: [ResolvedItem] {
        unclassified.compactMap { target in
            guard let entry = entries.first(where: { $0.id == target.entryID }),
                  let sense = entry.senses.first(where: { $0.id == target.senseID }) else { return nil }
            return ResolvedItem(selection: target, entry: entry, sense: sense)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(localized: "Other expressions", table: "Vocabulary"))
                        .font(textSize.font(28, weight: .bold))
                        .tracking(-0.3)
                    Text("\(resolvedItems.count)")
                        .font(textSize.font(12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    Spacer()
                    Button {
                        creatingBlankMeaning = true
                    } label: {
                        Label(String(localized: "New meaning", table: "Vocabulary"), systemImage: "plus")
                            .font(.caption.weight(.medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                if resolvedItems.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No matching expressions", table: "Vocabulary"), systemImage: "checkmark.circle")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(resolvedItems) { item in
                            unclassifiedCard(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { groupingSenseID != nil }, set: { if !$0 { groupingSenseID = nil } })) {
            if let senseID = groupingSenseID {
                VocabularyMeaningMappingEditor(store: store, senseID: senseID)
            }
        }
        .sheet(isPresented: Binding(get: { creatingMeaningFor != nil }, set: { if !$0 { creatingMeaningFor = nil } })) {
            if let selection = creatingMeaningFor {
                VocabularyMeaningEditor(store: store, linking: selection, preferredLanguages: meaningLanguages, onSaved: openMeaning)
            }
        }
        .sheet(isPresented: $creatingBlankMeaning) {
            VocabularyMeaningEditor(store: store, preferredLanguages: meaningLanguages, onSaved: openMeaning)
        }
    }

    private func unclassifiedCard(_ item: ResolvedItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                openSense(item.selection)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.entry.expression)
                        .font(textSize.font(17, weight: .semibold))
                        .foregroundStyle(.primary)
                    VocabularySenseSummary(sense: item.sense)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                if let speech {
                    LearningSpeechButton(
                        speech: speech,
                        request: SpeechRequest(
                            target: SpeechTarget(ownerID: item.sense.id, itemID: "unclassified.expression"),
                            text: item.entry.expression,
                            language: item.entry.language
                        ),
                        playLabel: String(localized: "Read aloud", table: "Vocabulary"),
                        stopLabel: String(localized: "Stop reading", table: "Vocabulary")
                    )
                }
                VocabularyExpressionLanguageBadge(language: item.entry.language)
                if store.semantics.nodes.isEmpty {
                    Button {
                        creatingMeaningFor = item.selection
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "New meaning", table: "Vocabulary"))
                } else {
                    Menu {
                        Button {
                            groupingSenseID = item.sense.id
                        } label: {
                            Label(String(localized: "Group by meaning", table: "Vocabulary"), systemImage: "folder.badge.plus")
                        }
                        Button {
                            creatingMeaningFor = item.selection
                        } label: {
                            Label(String(localized: "New meaning", table: "Vocabulary"), systemImage: "circle.hexagongrid")
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "Group by meaning", table: "Vocabulary"))
                }
                Button {
                    openSense(item.selection)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
        )
    }
}

/// Domain overview page shown when a learner selects a semantic category (whether populated or
/// unexplored) in the unified sidebar tree or taxonomy graph. Answers three core questions at
/// once: where this category sits in the semantic world, which sub-branches are still unexplored,
/// and which meaning groups and expressions belong to this domain.
struct VocabularyCategoryDetail: View {
    @ObservedObject var store: VocabularyStore
    let category: VocabularyCategory
    let entries: [VocabularyEntry]
    var speech: LearningSpeechController?
    let openCategory: (UUID) -> Void
    let openMeaning: (UUID) -> Void
    let openSense: (VocabularySelection) -> Void
    @Environment(\.vocabularyMeaningLanguages) private var languages
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var editingCategory = false
    @State private var creatingSubcategory = false
    @State private var creatingMeaning = false

    private var effectiveCategory: VocabularyCategoryLocalizationPolicy.Presentation {
        VocabularyClassificationPolicy.presentation(category, in: store.classification)
    }

    private var primaryTitle: String {
        VocabularyClassificationPolicy.title(category, in: store.classification)
    }

    private var breadcrumbItems: [VocabularyCategory] {
        let byID = Dictionary(uniqueKeysWithValues: store.classification.categories.map { ($0.id, $0) })
        let parents = Dictionary(grouping: store.classification.parents, by: \.categoryID)
        var chain: [VocabularyCategory] = []
        var cursor: UUID? = category.id
        var seen: Set<UUID> = [category.id]
        while let current = cursor,
              let parentID = parents[current]?.first?.parentID,
              seen.insert(parentID).inserted,
              let parent = byID[parentID], !parent.isRetired {
            chain.append(parent)
            cursor = parentID
        }
        return chain.reversed()
    }

    private var childCategories: [VocabularyCategory] {
        let hidden = Set(store.classification.overrides.filter(\.isHidden).map(\.categoryID))
        let childIDs = Set(
            store.classification.parents
                .filter { $0.parentID == category.id }
                .map(\.categoryID)
        )
        return store.classification.categories.filter {
            childIDs.contains($0.id) && !$0.isRetired && !hidden.contains($0.id)
        }
    }

    private var directMeaningItems: [VocabularyMeaningBrowserProjection.Item] {
        let directNodeIDs = Set(
            store.classification.memberships
                .filter { $0.categoryID == category.id && $0.provenance.status == .confirmed }
                .map(\.nodeID)
        )
        return VocabularyMeaningBrowserProjection.items(
            index: store.semantics,
            entries: entries,
            includeEmpty: true,
            preferredLanguages: languages
        ).filter { directNodeIDs.contains($0.id) }
    }

    private var descendantMeaningItems: [VocabularyMeaningBrowserProjection.Item] {
        let allNodeIDs = VocabularyClassificationPolicy.meaningIDs(in: category.id, index: store.classification)
        let directNodeIDs = Set(directMeaningItems.map(\.id))
        let inheritedIDs = allNodeIDs.subtracting(directNodeIDs)
        return VocabularyMeaningBrowserProjection.items(
            index: store.semantics,
            entries: entries,
            includeEmpty: true,
            preferredLanguages: languages
        ).filter { inheritedIDs.contains($0.id) }
    }

    private var totalMeaningCount: Int {
        directMeaningItems.count + descendantMeaningItems.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                categoryHeader
                if !childCategories.isEmpty {
                    subcategoriesSection
                }
                meaningsSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $editingCategory) {
            VocabularyCategoryEditor(store: store, category: category, preferredLanguages: languages)
        }
        .sheet(isPresented: $creatingSubcategory) {
            VocabularyCategoryEditor(store: store, parentID: category.id, axis: category.axis, preferredLanguages: languages) { id in
                openCategory(id)
            }
        }
        .sheet(isPresented: $creatingMeaning) {
            VocabularyMeaningEditor(
                store: store,
                categoryID: category.id,
                preferredLanguages: languages,
                onSaved: openMeaning
            )
        }
    }

    private var categoryHeader: some View {
        let tint = category.axis.tint
        let icon = VocabularyClassificationProjection.symbolName(for: category, in: store.classification)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: category.axis.symbolName)
                        .font(.system(size: textSize.size(10), weight: .semibold))
                    Text(category.axis.label)
                        .font(textSize.font(11.5, weight: .semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.11), in: Capsule(style: .continuous))

                ForEach(breadcrumbItems) { ancestor in
                    Image(systemName: "chevron.right")
                        .font(.system(size: textSize.size(9), weight: .bold))
                        .foregroundStyle(.tertiary)
                    Button {
                        openCategory(ancestor.id)
                    } label: {
                        Text(VocabularyClassificationPolicy.title(ancestor, in: store.classification))
                            .font(textSize.font(12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: textSize.size(21), weight: .semibold))
                    .foregroundStyle(tint)
                Text(primaryTitle)
                    .font(textSize.font(28, weight: .bold))
                    .tracking(-0.3)
                    .textSelection(.enabled)
                if totalMeaningCount == 0 {
                    Text(String(localized: "Unexplored", table: "Vocabulary"))
                        .font(textSize.font(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
                        )
                }
                Spacer(minLength: 8)
                Button {
                    creatingMeaning = true
                } label: {
                    Label(String(localized: "New meaning", table: "Vocabulary"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Menu {
                    Button(String(localized: "Edit category", table: "Vocabulary")) { editingCategory = true }
                    Button(String(localized: "New category", table: "Vocabulary")) { creatingSubcategory = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !effectiveCategory.definition.isEmpty {
                Text(effectiveCategory.definition)
                    .font(textSize.font(16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
    }

    private var subcategoriesSection: some View {
        let tint = category.axis.tint
        let validNodeIDs = Set(store.semantics.nodes.map(\.id))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(String(localized: "Subcategories", table: "Vocabulary"))
                    .font(textSize.font(14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    creatingSubcategory = true
                } label: {
                    Label(String(localized: "New category", table: "Vocabulary"), systemImage: "folder.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 280), spacing: 8)], spacing: 8) {
                ForEach(childCategories) { child in
                    let count = VocabularyClassificationPolicy.meaningIDs(in: child.id, index: store.classification)
                        .intersection(validNodeIDs)
                        .count
                    let isUnexplored = count == 0
                    Button {
                        openCategory(child.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: isUnexplored ? "circle.dashed" : "folder.fill")
                                .font(.system(size: textSize.size(11.5), weight: .semibold))
                                .foregroundStyle(isUnexplored ? .secondary : tint)
                            Text(VocabularyClassificationPolicy.title(child, in: store.classification))
                                .font(textSize.font(13, weight: isUnexplored ? .regular : .medium))
                                .foregroundStyle(isUnexplored ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: textSize.size(10.5), weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(tint.opacity(0.12), in: Capsule(style: .continuous))
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isUnexplored ? Color.primary.opacity(0.015) : Color.primary.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isUnexplored ? Color.primary.opacity(0.1) : tint.opacity(0.2),
                                    style: isUnexplored ? StrokeStyle(lineWidth: 0.75, dash: [3, 2]) : StrokeStyle(lineWidth: 0.5)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var meaningsSection: some View {
        let allItems = directMeaningItems + descendantMeaningItems
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(String(localized: "Meaning groups", table: "Vocabulary"))
                    .font(textSize.font(15, weight: .semibold))
                if !allItems.isEmpty {
                    Text("\(allItems.count)")
                        .font(textSize.font(11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(category.axis.tint)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(category.axis.tint.opacity(0.12), in: Capsule(style: .continuous))
                }
                Spacer()
            }

            if allItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: textSize.size(15), weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "No meanings in this category yet", table: "Vocabulary"))
                            .font(textSize.font(14.5, weight: .semibold))
                    }
                    Text(String(localized:
                        "Create a meaning group here to organize expressions that share this semantic role.",
                        table: "Vocabulary"))
                        .font(textSize.font(13.5))
                        .foregroundStyle(.secondary)
                    Button {
                        creatingMeaning = true
                    } label: {
                        Label(String(localized: "New meaning", table: "Vocabulary"), systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
                )
            } else {
                ForEach(allItems) { item in
                    meaningSummaryCard(item)
                }
            }
        }
    }

    private func meaningSummaryCard(_ item: VocabularyMeaningBrowserProjection.Item) -> some View {
        let tint: Color = item.node.kind == .concept ? LingroveBrand.accent : .teal
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    openMeaning(item.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.node.kind.symbolName)
                            .font(.system(size: textSize.size(12), weight: .semibold))
                            .foregroundStyle(tint)
                        Text(item.title)
                            .font(textSize.font(16.5, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)

                if !item.node.definition.isEmpty {
                    Text(item.node.definition)
                        .font(textSize.font(13.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    openMeaning(item.id)
                } label: {
                    HStack(spacing: 4) {
                        Text("\(item.selections.count)")
                            .font(textSize.font(11.5, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: textSize.size(9.5), weight: .bold))
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.11), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if !item.selections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.selections, id: \.senseID) { selection in
                            if let entry = entries.first(where: { $0.id == selection.entryID }),
                               let sense = entry.senses.first(where: { $0.id == selection.senseID }) {
                                Button {
                                    openSense(selection)
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(entry.expression)
                                            .font(textSize.font(13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        if !sense.displayTitle.isEmpty {
                                            Text("· " + sense.displayTitle)
                                                .font(textSize.font(12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(Color.primary.opacity(0.045), in: Capsule(style: .continuous))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
        )
    }
}
