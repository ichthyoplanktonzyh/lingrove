import AppKit
import SwiftUI

/// Native graph chrome borrows the existing window's selection and details. The representable
/// owns mouse/trackpad drawing; SwiftUI owns ordinary buttons, the legend and the settings form.
/// When a floating detail drawer is open on the trailing edge, `trailingInset` shifts the
/// top-right settings button and bottom-right camera HUD smoothly so they remain unobstructed.
struct VocabularyGraphView: View {
    let entries: [VocabularyEntry]
    let query: String
    let selection: VocabularySelection?
    @ObservedObject var presentation: VocabularyGraphPresentation
    let select: (VocabularySelection?) -> Void
    var interactionBegan: (() -> Void)?
    var trailingInset: CGFloat = 0
    @State private var showingSettings = false

    var body: some View {
        let snapshot = VocabularyGraphProjection.make(entries: entries, expanded: presentation.expanded, query: query)
        VocabularyGraphCanvas(snapshot: snapshot, selection: selection, presentation: presentation,
            select: select, interactionBegan: interactionBegan)
            .overlay(alignment: .topTrailing) {
                Button { interactionBegan?(); showingSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                .padding(.top, 14)
                .padding(.trailing, 14 + trailingInset)
                .help(String(localized: "Graph settings", table: "Vocabulary"))
                .accessibilityLabel(String(localized: "Graph settings", table: "Vocabulary"))
                .popover(isPresented: $showingSettings, arrowEdge: .trailing) {
                    VocabularyGraphSettingsView(presentation: presentation)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.primary.opacity(0.72))
                            .frame(width: 8, height: 8)
                        Text(String(localized: "Headwords", table: "Vocabulary"))
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .stroke(LingroveBrand.accent, lineWidth: 1.6)
                            .frame(width: 7, height: 7)
                        Text(String(localized: "Senses", table: "Vocabulary"))
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .padding(14)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    control("minus", label: "Zoom out", command: .zoomOut)
                    control("plus", label: "Zoom in", command: .zoomIn)
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 3)
                    control("arrow.up.left.and.arrow.down.right", label: "Fit graph", command: .fit)
                    control("scope", label: "Locate selection", command: .locate)
                    Button { interactionBegan?(); presentation.collapse(); select(nil) } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .help(String(localized: "Collapse senses", table: "Vocabulary"))
                    .accessibilityLabel(String(localized: "Collapse senses", table: "Vocabulary"))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.07), radius: 6, y: 2)
                .padding(.bottom, 14)
                .padding(.trailing, 14 + trailingInset)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(String(localized: "No matching expressions", table: "Vocabulary"), systemImage: "network")
                }
            }
    }

    private func control(_ symbol: String, label: String.LocalizationValue,
                         command: VocabularyGraphPresentation.Command) -> some View {
        Button { interactionBegan?(); presentation.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .help(String(localized: label, table: "Vocabulary"))
        .accessibilityLabel(String(localized: label, table: "Vocabulary"))
    }
}

private struct VocabularyGraphCanvas: NSViewRepresentable {
    let snapshot: VocabularyGraphSnapshot
    let selection: VocabularySelection?
    let presentation: VocabularyGraphPresentation
    let select: (VocabularySelection?) -> Void
    let interactionBegan: (() -> Void)?

    func makeNSView(context: Context) -> VocabularyGraphCanvasView {
        VocabularyGraphCanvasView(presentation: presentation)
    }
    func updateNSView(_ view: VocabularyGraphCanvasView, context: Context) {
        view.interactionBegan = interactionBegan
        view.update(snapshot: snapshot, selection: selection, select: select)
    }
    static func dismantleNSView(_ view: VocabularyGraphCanvasView, coordinator: ()) { view.suspend() }
}

private struct VocabularyGraphSettingsView: View {
    @ObservedObject var presentation: VocabularyGraphPresentation
    var body: some View {
        Form {
            Section(String(localized: "Appearance", table: "Vocabulary")) {
                slider("Node size", value: $presentation.settings.nodeSize, range: 8...28)
                slider("Link thickness", value: $presentation.settings.linkWidth, range: 0.5...3)
                Picker(String(localized: "Labels", table: "Vocabulary"), selection: $presentation.settings.labels) {
                    Text(String(localized: "Automatic", table: "Vocabulary")).tag(VocabularyGraphSettings.Labels.automatic)
                    Text(String(localized: "All labels", table: "Vocabulary")).tag(VocabularyGraphSettings.Labels.all)
                    Text(String(localized: "Focused labels", table: "Vocabulary")).tag(VocabularyGraphSettings.Labels.focused)
                }
            }
            Section(String(localized: "Forces", table: "Vocabulary")) {
                slider("Center force", value: $presentation.settings.center, range: 0...0.08)
                slider("Repel force", value: $presentation.settings.repulsion, range: 10...1200)
                slider("Link force", value: $presentation.settings.linkStrength, range: 0...0.7)
                slider("Link distance", value: $presentation.settings.linkDistance, range: 60...240)
            }
            Button(String(localized: "Restore graph defaults", table: "Vocabulary")) { presentation.settings = .init() }
        }.formStyle(.grouped).frame(width: 330).fixedSize(horizontal: false, vertical: true)
    }
    private func slider(_ label: String.LocalizationValue, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Slider(value: value, in: range) { Text(String(localized: label, table: "Vocabulary")) }
    }
}
