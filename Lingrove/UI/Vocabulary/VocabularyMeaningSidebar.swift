import SwiftUI

/// The native sidebar lists meaning groups, not duplicated expressions. Unclassified senses
/// retain their lexical identities and remain reachable before any semantic association exists.
struct VocabularyMeaningSidebar: View {
    let items: [VocabularyMeaningBrowserProjection.Item]
    let entries: [VocabularyEntry]
    let unclassified: [VocabularySelection]
    var isDetailed = false
    @Binding var destination: VocabularyMeaningDestination?
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var isUnclassifiedExpanded = false

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
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.node.kind.symbolName)
                            .font(.system(size: textSize.size(11, sidebar: true), weight: .semibold))
                            .foregroundStyle(item.node.kind == .concept ? LingroveBrand.accent : .teal)
                        Text(item.title)
                            .font(textSize.font(14.5, weight: .semibold, sidebar: true))
                            .lineLimit(1)
                        if !isDetailed && isSelected && !preview.isEmpty {
                            Text(preview)
                                .font(textSize.font(12.5, sidebar: true))
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
                            .font(.system(size: textSize.size(10.5, sidebar: true), weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(item.selections.isEmpty ? Color.secondary : LingroveBrand.accent)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(item.selections.isEmpty ? Color.primary.opacity(0.06) : LingroveBrand.accent.opacity(0.12))
                            )
                    }
                    if isDetailed && !preview.isEmpty {
                        Text(preview)
                            .font(textSize.font(13, sidebar: true))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 16)
                    }
                }
                .padding(.vertical, isDetailed ? 4 : 2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.14), value: isSelected)
                .tag(VocabularyMeaningDestination.node(item.id))
            }

            if !unclassified.isEmpty {
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
        }
        .onChange(of: destination, initial: true) { _, next in
            if case .unclassified = next {
                isUnclassifiedExpanded = true
            } else if case .sense(nodeID: nil, senseID: _) = next {
                isUnclassifiedExpanded = true
            }
        }
        .accessibilityIdentifier("vocabularyMeaningList")
    }
}
