import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A drag belongs to one notebook window and revision. Its IDs describe an explicit user
/// choice; neither the row nor the archive infers equivalence from the displayed wording.
struct VocabularySenseDrag: Codable, Equatable, Sendable {
    static let type = UTType(exportedAs: "io.ichthyoplanktonzyh.lingrove.sense-merge")
    let entryID: UUID
    let senseID: UUID
    let scopeIdentity: UUID
    let revision: UInt64

    func canMerge(into target: Self) -> Bool {
        entryID == target.entryID && senseID != target.senseID &&
            scopeIdentity == target.scopeIdentity && revision == target.revision
    }
}

/// Adds native drag/drop to existing rows without replacing their components or icons.
/// The notebook owns the shared drag value and save callback; this modifier owns hover only.
struct VocabularySenseMergeInteraction: ViewModifier {
    let target: VocabularySenseDrag
    @Binding var dragging: VocabularySenseDrag?
    let onMerge: (VocabularySenseDrag, VocabularySenseDrag) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(targeted ? Color.accentColor.opacity(0.14) : Color.clear)
            .overlay(alignment: .bottomLeading) {
                if targeted {
                    Text(String(localized: "Merge here; keep this sense’s explanation", table: "Vocabulary"))
                        .font(.caption2).padding(4).background(.regularMaterial)
                        .allowsHitTesting(false)
                }
            }
            .onDrag {
                dragging = target
                let provider = NSItemProvider()
                let data = try? JSONEncoder().encode(target)
                provider.registerDataRepresentation(forTypeIdentifier: VocabularySenseDrag.type.identifier,
                    visibility: .ownProcess) { completion in completion(data, nil); return nil }
                return provider
            }
            .onDrop(of: [VocabularySenseDrag.type], delegate: SenseDrop(target: target,
                dragging: $dragging, targeted: $targeted, onMerge: onMerge))
    }

    private struct SenseDrop: DropDelegate {
        let target: VocabularySenseDrag
        @Binding var dragging: VocabularySenseDrag?
        @Binding var targeted: Bool
        let onMerge: (VocabularySenseDrag, VocabularySenseDrag) -> Void

        func validateDrop(info: DropInfo) -> Bool { dragging?.canMerge(into: target) == true }
        func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
        func dropExited(info: DropInfo) { targeted = false }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
        }
        func performDrop(info: DropInfo) -> Bool {
            targeted = false
            guard let source = dragging, source.canMerge(into: target),
                  let provider = info.itemProviders(for: [VocabularySenseDrag.type]).first else { return false }
            dragging = nil
            provider.loadDataRepresentation(forTypeIdentifier: VocabularySenseDrag.type.identifier) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(VocabularySenseDrag.self, from: data),
                      payload == source else { return }
                Task { @MainActor in onMerge(payload, target) }
            }
            return true
        }
    }
}
