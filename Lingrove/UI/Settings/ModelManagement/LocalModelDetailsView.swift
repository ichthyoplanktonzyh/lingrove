import SwiftUI

/// A retained setting must name its problem, rather than pretending it is an empty selection.
/// Views borrow this stateless formatter; it never repairs or persists the selected filename.
enum LocalModelSelectionLabel {
    static func unavailable(_ filename: String, task: LocalModelTask) -> String {
        let name = LocalModelCatalog.displayName(for: filename)
        return LocalModelTaskPolicy.supports(filename, task: task)
            ? String(localized: "\(name) (file unavailable)", table: "Learning")
            : String(localized: "\(name) · not compatible with this task", table: "Learning")
    }
}

/// Presentation-only metadata disclosure, shared by installed and downloadable rows. The row
/// supplies identities/URLs; opening this view never reads GGUF metadata or starts a download.
struct LocalModelDetailsView: View {
    let filename: String
    var location: URL?
    var source: URL?
    @State private var expanded: Bool

    init(filename: String, location: URL? = nil, source: URL? = nil, initiallyExpanded: Bool = false) {
        self.filename = filename
        self.location = location
        self.source = source
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(String(localized: "Model details", table: "Learning"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filename).font(.caption.monospaced()).textSelection(.enabled)
                if let descriptor = LocalModelCatalog.descriptor(for: filename) {
                    LabeledContent(String(localized: "Quantization", table: "Learning"), value: descriptor.quantization)
                }
                if let source {
                    LabeledContent(String(localized: "Model source", table: "Learning"), value: source.host ?? source.absoluteString)
                    Text(source.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                } else if let source = LocalModelCatalog.downloadMetadata(for: filename)?.downloadURL {
                    LabeledContent(String(localized: "Catalog source", table: "Learning"), value: source.host ?? source.absoluteString)
                    Text(source.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let location {
                    Text(location.path).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
        }
        .font(.caption).accessibilityIdentifier("localModelDetails")
    }
}
