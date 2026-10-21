import AppKit
import SwiftUI

/// Native graph chrome borrows the existing window's selection and details. The representable
/// owns mouse/trackpad drawing; SwiftUI owns ordinary buttons, the legend and the settings form.
struct VocabularyGraphView: View {
    let entries: [VocabularyEntry]
    let query: String
    let selection: VocabularySelection?
    @ObservedObject var presentation: VocabularyGraphPresentation
    let select: (VocabularySelection?) -> Void
    @State private var showingSettings = false

    var body: some View {
        let snapshot = VocabularyGraphProjection.make(entries: entries, expanded: presentation.expanded, query: query)
        VocabularyGraphCanvas(snapshot: snapshot, selection: selection, presentation: presentation, select: select)
            .overlay(alignment: .topTrailing) {
                Button { showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).padding(14)
                    .help(String(localized: "Graph settings", table: "Vocabulary"))
                    .accessibilityLabel(String(localized: "Graph settings", table: "Vocabulary"))
                    .popover(isPresented: $showingSettings, arrowEdge: .trailing) {
                        VocabularyGraphSettingsView(presentation: presentation)
                    }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 12) {
                    Label { Text(String(localized: "Headwords", table: "Vocabulary")) } icon: {
                        Circle().fill(.secondary).frame(width: 8, height: 8)
                    }
                    Label { Text(String(localized: "Senses", table: "Vocabulary")) } icon: {
                        Circle().stroke(.blue, lineWidth: 1).frame(width: 6, height: 6)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(16).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    control("minus", label: "Zoom out", command: .zoomOut)
                    control("plus", label: "Zoom in", command: .zoomIn)
                    control("arrow.up.left.and.arrow.down.right", label: "Fit graph", command: .fit)
                    control("scope", label: "Locate selection", command: .locate)
                    Button { presentation.collapse(); select(nil) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .help(String(localized: "Collapse senses", table: "Vocabulary"))
                        .accessibilityLabel(String(localized: "Collapse senses", table: "Vocabulary"))
                }.buttonStyle(.borderless).padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(String(localized: "No matching expressions", table: "Vocabulary"), systemImage: "network")
                }
            }
    }

    private func control(_ symbol: String, label: String.LocalizationValue,
                         command: VocabularyGraphPresentation.Command) -> some View {
        Button { presentation.send(command) } label: { Image(systemName: symbol).frame(width: 25, height: 22) }
            .help(String(localized: label, table: "Vocabulary"))
            .accessibilityLabel(String(localized: label, table: "Vocabulary"))
    }
}

private struct VocabularyGraphCanvas: NSViewRepresentable {
    let snapshot: VocabularyGraphSnapshot
    let selection: VocabularySelection?
    let presentation: VocabularyGraphPresentation
    let select: (VocabularySelection?) -> Void

    func makeNSView(context: Context) -> VocabularyGraphCanvasView {
        VocabularyGraphCanvasView(presentation: presentation)
    }
    func updateNSView(_ view: VocabularyGraphCanvasView, context: Context) {
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
