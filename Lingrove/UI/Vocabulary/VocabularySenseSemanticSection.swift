import LingroveNotebook
import SwiftUI

/// The sense reader borrows adopted semantic links from the store. Agent organization owns
/// mutations; this surface navigates to meanings without editing shared nodes or mappings.
struct VocabularySenseSemanticSection: View {
    @ObservedObject var store: VocabularyStore
    let selection: VocabularySelection
    var openMeaning: ((UUID) -> Void)?
    @Environment(\.vocabularyMeaningLanguages) private var meaningLanguages
    @Environment(\.vocabularyTextSize) private var textSize

    private var mappings: [VocabularyMeaningMapping] {
        var seen = Set<UUID>()
        return store.semantics.mappings.filter {
            $0.senseID == selection.senseID && $0.provenance.status == .confirmed && seen.insert($0.nodeID).inserted
        }
    }
    static func hasContent(in index: VocabularySemanticIndex, for senseID: UUID) -> Bool {
        index.mappings.contains { $0.senseID == senseID && $0.provenance.status == .confirmed }
    }

    var body: some View {
        if !mappings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "By meaning", table: "Vocabulary"), systemImage: "circle.hexagongrid")
                    .font(textSize.font(12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(mappings.enumerated()), id: \.element.id) { index, mapping in
                    if index > 0 { Divider().opacity(0.45) }
                    if let node = store.semantics.nodes.first(where: { $0.id == mapping.nodeID }) {
                        mappingBlock(mapping: mapping, node: node)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5))
        }
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
                            .font(.system(size: textSize.size(11), weight: .semibold))
                        Text(node.title(in: meaningLanguages))
                            .font(textSize.font(12.5, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: textSize.size(9), weight: .bold))
                            .opacity(0.75)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(tint.opacity(0.11), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()

            }

        }
    }
}
