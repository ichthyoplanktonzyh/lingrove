import SwiftUI

/// Compact icon menu placed in the entry detail header so learners can link a sense to a
/// meaning group or add a usage pattern on demand, without keeping an unfinished "Organize"
/// disclosure row permanently visible in the dictionary reading flow.
struct VocabularySenseOrganizeMenuButton: View {
    @ObservedObject var store: VocabularyStore
    let selection: VocabularySelection
    var openMeaning: ((UUID) -> Void)?
    @Environment(\.vocabularyMeaningLanguages) private var meaningLanguages
    @State private var creatingMeaning = false
    @State private var addingMapping = false
    @State private var addingPattern = false
    @State private var hovering = false

    var body: some View {
        Menu {
            Button {
                addingMapping = true
            } label: {
                Label(String(localized: "Group by meaning", table: "Vocabulary"), systemImage: "folder.badge.plus")
            }
            .disabled(store.semantics.nodes.isEmpty)

            Button {
                creatingMeaning = true
            } label: {
                Label(String(localized: "New meaning", table: "Vocabulary"), systemImage: "circle.hexagongrid")
            }

            Divider()

            Button {
                addingPattern = true
            } label: {
                Label(String(localized: "Add usage pattern", table: "Vocabulary"), systemImage: "text.quote")
            }
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonStyle(LearningIconActionButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help(String(localized: "Group by meaning", table: "Vocabulary"))
        .accessibilityLabel(String(localized: "Group by meaning", table: "Vocabulary"))
        .sheet(isPresented: $creatingMeaning) {
            VocabularyMeaningEditor(
                store: store,
                linking: selection,
                preferredLanguages: meaningLanguages,
                onSaved: { id in openMeaning?(id) }
            )
        }
        .sheet(isPresented: $addingMapping) {
            VocabularyMeaningMappingEditor(store: store, senseID: selection.senseID)
        }
        .sheet(isPresented: $addingPattern) {
            VocabularyUsagePatternEditor(store: store, senseID: selection.senseID)
        }
    }
}

/// Displays established meaning groups and usage patterns for a sense inside a cohesive
/// callout card. Only rendered when the sense actually has semantic links or usage patterns,
/// keeping ordinary vocabulary entries completely free of form clutter.
struct VocabularySenseSemanticSection: View {
    @ObservedObject var store: VocabularyStore
    let selection: VocabularySelection
    var openMeaning: ((UUID) -> Void)?
    @Environment(\.vocabularyMeaningLanguages) private var meaningLanguages
    @State private var creatingMeaning = false
    @State private var addingMapping = false
    @State private var editingMapping: VocabularyMeaningMapping?
    @State private var addingPattern = false
    @State private var editingPattern: VocabularyUsagePattern?
    @State private var deletingPattern: VocabularyUsagePattern?

    static func hasContent(in index: VocabularySemanticIndex, for senseID: UUID) -> Bool {
        index.mappings.contains { $0.senseID == senseID } ||
            index.patterns.contains { $0.senseID == senseID }
    }

    private var mappings: [VocabularyMeaningMapping] { store.semantics.mappings.filter { $0.senseID == selection.senseID } }
    private var patterns: [VocabularyUsagePattern] { store.semantics.patterns.filter { $0.senseID == selection.senseID } }
    private var standalonePatterns: [VocabularyUsagePattern] {
        patterns.filter { pattern in !mappings.contains { $0.patternID == pattern.id } }
    }
    private var sense: VocabularySense? {
        store.entries.first { $0.id == selection.entryID }?.senses.first { $0.id == selection.senseID }
    }
    private var hasSemanticContent: Bool {
        !mappings.isEmpty || !patterns.isEmpty
    }

    var body: some View {
        if hasSemanticContent {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Label(String(localized: "By meaning", table: "Vocabulary"), systemImage: "circle.hexagongrid")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    addMoreMenu
                }

                ForEach(Array(mappings.enumerated()), id: \.element.id) { index, mapping in
                    if index > 0 {
                        Divider().opacity(0.45)
                    }
                    if let node = store.semantics.nodes.first(where: { $0.id == mapping.nodeID }) {
                        mappingBlock(mapping: mapping, node: node)
                    }
                }

                // A pattern already shown with its mapping must not be repeated as another task.
                ForEach(Array(standalonePatterns.enumerated()), id: \.element.id) { index, pattern in
                    if !mappings.isEmpty || index > 0 {
                        Divider().opacity(0.45)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        VocabularyUsagePatternSummary(pattern: pattern)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        patternMenu(pattern)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
            )
            .sheet(isPresented: $creatingMeaning) {
                VocabularyMeaningEditor(store: store, linking: selection, preferredLanguages: meaningLanguages)
            }
            .sheet(isPresented: $addingMapping) { VocabularyMeaningMappingEditor(store: store, senseID: selection.senseID) }
            .sheet(item: $editingMapping) { VocabularyMeaningMappingEditor(store: store, senseID: selection.senseID, mapping: $0) }
            .sheet(isPresented: $addingPattern) { VocabularyUsagePatternEditor(store: store, senseID: selection.senseID) }
            .sheet(item: $editingPattern) { VocabularyUsagePatternEditor(store: store, senseID: selection.senseID, pattern: $0) }
            .confirmationDialog(String(localized: "Remove this wording and its groupings?", table: "Vocabulary"),
                isPresented: Binding(get: { deletingPattern != nil }, set: { if !$0 { deletingPattern = nil } })) {
                    Button(String(localized: "Remove", table: "Vocabulary"), role: .destructive) {
                        guard let pattern = deletingPattern else { return }
                        let baseline = store.semantics; var edited = baseline
                        VocabularySemanticPolicy.removePattern(pattern.id, from: &edited)
                        Task { _ = await store.updateSemantics(edited, basedOn: baseline) }
                        deletingPattern = nil
                    }
                }
        }
    }

    private var addMoreMenu: some View {
        Menu {
            Button {
                addingMapping = true
            } label: {
                Label(String(localized: "Group by meaning", table: "Vocabulary"), systemImage: "folder.badge.plus")
            }
            .disabled(store.semantics.nodes.isEmpty)

            Button {
                creatingMeaning = true
            } label: {
                Label(String(localized: "New meaning", table: "Vocabulary"), systemImage: "circle.hexagongrid")
            }

            Divider()

            Button {
                addingPattern = true
            } label: {
                Label(String(localized: "Add usage pattern", table: "Vocabulary"), systemImage: "text.quote")
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Group by meaning", table: "Vocabulary"))
    }

    private func mappingBlock(mapping: VocabularyMeaningMapping, node: VocabularyMeaningNode) -> some View {
        let tint: Color = node.kind == .concept ? LingroveBrand.accent : .teal
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    openMeaning?(node.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: node.kind.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(node.title(in: meaningLanguages))
                            .font(.caption.weight(.semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.75)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(tint.opacity(0.11), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()

                if mapping.provenance.status != .proposed {
                    Menu {
                        Button(String(localized: "Change", table: "Learning")) { editingMapping = mapping }
                        if let pattern = patterns.first(where: { $0.id == mapping.patternID }) {
                            Button(String(localized: "Edit usage pattern", table: "Vocabulary")) { editingPattern = pattern }
                        }
                        Divider()
                        Button(String(localized: "Remove from this group", table: "Vocabulary"), role: .destructive) {
                            removeMapping(mapping)
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
            }

            if mappingHasDetails(mapping) {
                VocabularyMeaningMappingSummary(
                    store: store,
                    mapping: mapping,
                    sense: sense,
                    showsExample: false,
                    showsActionsMenu: mapping.provenance.status == .proposed,
                    edit: { editingMapping = mapping }
                )
            }
        }
    }

    private func mappingHasDetails(_ mapping: VocabularyMeaningMapping) -> Bool {
        let hasPattern = patterns.contains { $0.id == mapping.patternID }
        return hasPattern || !mapping.nuance.isEmpty || !mapping.conditions.isEmpty ||
            !mapping.provenance.source.isEmpty || mapping.provenance.status == .proposed
    }

    private func patternMenu(_ pattern: VocabularyUsagePattern) -> some View {
        Menu {
            Button(String(localized: "Edit", table: "Vocabulary")) { editingPattern = pattern }
            Divider()
            Button(String(localized: "Remove", table: "Vocabulary"), role: .destructive) { deletingPattern = pattern }
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

    private func removeMapping(_ mapping: VocabularyMeaningMapping) {
        let baseline = store.semantics; var edited = baseline
        edited.mappings.removeAll { $0.id == mapping.id }
        Task { _ = await store.updateSemantics(edited, basedOn: baseline) }
    }
}
