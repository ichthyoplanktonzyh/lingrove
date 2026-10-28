import SwiftUI

/// The native sidebar lists meaning groups, not duplicated expressions. Unclassified senses
/// retain their lexical identities and remain reachable before any semantic association exists.
struct VocabularyMeaningSidebar: View {
    let items: [VocabularyMeaningBrowserProjection.Item]
    let entries: [VocabularyEntry]
    let unclassified: [VocabularySelection]
    var isDetailed = false
    @Binding var destination: VocabularyMeaningDestination?

    private var showingUnclassified: Bool {
        switch destination {
        case .unclassified, .sense(nodeID: nil, senseID: _): true
        default: false
        }
    }

    private var sidebarSelection: Binding<VocabularyMeaningDestination?> {
        Binding(get: {
            if let nodeID = destination?.nodeID { return .node(nodeID) }
            if case .unclassified = destination { return .unclassified }
            return destination?.senseID.map { .sense(nodeID: nil, senseID: $0) }
        }, set: { value in
            if let value { destination = value }
        })
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
        List(selection: sidebarSelection) {
            ForEach(items) { item in
                let isSelected = destination?.nodeID == item.id
                let preview = expressionPreview(for: item)
                Button { destination = .node(item.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.node.kind.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(item.node.kind == .concept ? LingroveBrand.accent : .teal)
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if item.pendingCount > 0 {
                                Text(String(localized: "Suggested grouping", table: "Vocabulary"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.12), in: Capsule(style: .continuous))
                            }
                            Text("\(item.selections.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(item.selections.isEmpty ? Color.secondary : LingroveBrand.accent)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(item.selections.isEmpty ? Color.primary.opacity(0.06) : LingroveBrand.accent.opacity(0.12))
                                )
                        }
                        if (isDetailed || isSelected) && !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, isDetailed ? 4 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(VocabularyMeaningDestination.node(item.id))
                .listRowBackground(isSelected ? LingroveBrand.accent.opacity(0.12) : Color.clear)
            }
            Section {
                DisclosureGroup(isExpanded: Binding(get: { showingUnclassified }, set: { destination = $0 ? .unclassified : nil })) {
                    ForEach(unclassified, id: \.senseID) { target in
                        if let entry = entries.first(where: { $0.id == target.entryID }),
                           let sense = entry.senses.first(where: { $0.id == target.senseID }) {
                            let isSenseSelected = destination?.nodeID == nil && destination?.senseID == sense.id
                            Button { destination = .sense(nodeID: nil, senseID: sense.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(entry.expression)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        VocabularyExpressionLanguageBadge(language: entry.language)
                                    }
                                    if !sense.displayTitle.isEmpty {
                                        Text(sense.displayTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(VocabularyMeaningDestination.sense(nodeID: nil, senseID: sense.id))
                            .listRowBackground(isSenseSelected ? LingroveBrand.accent.opacity(0.12) : Color.clear)
                        }
                    }
                } label: {
                    Button {
                        destination = .unclassified
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "tray")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(String(localized: "Other expressions", table: "Vocabulary"))
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(unclassified.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier("vocabularyMeaningList")
    }
}
