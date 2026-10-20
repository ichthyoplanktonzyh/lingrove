import SwiftUI

/// Cards and the notebook borrow the same source selector. It owns only hover/popover state;
/// the injected query session owns provider choices, loading and request identities. Registering
/// popup windows preserves the floating card's internal-click behavior in both hosts.
struct LearningDictionarySourcePicker: View {
    @ObservedObject var session: LearningDictionarySession
    var popupWindows: LearningPopupWindowRegistry?
    @State private var showsSources = false
    @State private var sourceHovering = false
    private var canSelectSource: Bool {
        session.availableSources.count > 1 ||
            (!session.availableSources.isEmpty && !session.availableSources.contains(session.selectedSource))
    }
    var body: some View {
        Button { showsSources.toggle() } label: {
            HStack(spacing: 4) {
                Text(session.sourceName).lineLimit(1)
                if canSelectSource { Image(systemName: "chevron.down").font(.caption2) }
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(DictionarySourceButtonStyle(hovering: sourceHovering))
        .onHover { sourceHovering = $0 }
        .disabled(!canSelectSource)
        .accessibilityLabel(String(localized: "Dictionary sources", table: "Learning"))
        .accessibilityValue(session.sourceName)
        .accessibilityIdentifier("learning.dictionary.sources")
        // Register the content's actual window, including the period when SwiftUI has not
        // attached it as an AppKit child. Parent-chain discovery remains a fallback.
        .popover(isPresented: $showsSources) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.availableSources) { source in
                        DictionarySourceRow(title: session.name(for: source), subtitle: session.languageLabel(for: source),
                                            selected: source == session.selectedSource) {
                            showsSources = false
                            session.selectSource(source)
                        }
                        .accessibilityIdentifier("learning.dictionary.source.\(source.id)")
                    }
                }.padding(14)
            }.frame(width: 260, height: min(360, CGFloat(session.availableSources.count) * 54 + 28))
                .background(LearningPopoverWindowReader(registry: popupWindows).frame(width: 0, height: 0))
        }
        .onChange(of: session.query) { _, _ in showsSources = false }
    }

}

/// A live provider result, never an archived dictionary snapshot. The owning card or notebook
/// supplies one session and a bounded scroll viewport; this view shares HTML, MDict resources,
/// source attribution and link handling without constructing another provider or runtime.
struct LearningDictionaryDefinitionView: View {
    @ObservedObject var session: LearningDictionarySession
    var measured: (UUID) -> Void = { _ in }
    @State private var htmlHeight: CGFloat = 120
    private func articleHeight(for requestID: UUID) -> Binding<CGFloat> {
        Binding(get: { htmlHeight }, set: { height in
            guard session.requestIdentity == requestID, height.isFinite, height > 0 else { return }
            htmlHeight = height
            measured(requestID)
        })
    }

    @ViewBuilder var body: some View {
        switch session.content {
        case .loading:
            ProgressView(String(localized: "Looking up…", table: "Learning",
                comment: "Progress label while a dictionary lookup is running.")).font(.caption)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.secondary)
        case .result(.notFound):
            Text(session.selectedWord == nil && session.unit?.kind != .word
                ? String(localized: "No dictionary entry was found for this expression. Select a word below to look it up.",
                    table: "Learning", comment: "Empty state when the complete expression has no dictionary entry.")
                : String(localized: "No definition for this word was found in the available dictionaries.",
                    table: "Learning", comment: "Empty state when the configured dictionaries have no entry for a word."))
                .font(.callout).foregroundStyle(.secondary)
        case .result(.systemText(let text)):
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .result(.article(let article)):
            if article.html.isEmpty {
                Text(article.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                DictionaryHTMLView(article: article, loadResource: session.resourceLoader(for: article.resourceLibrary),
                               reference: session.followReference, height: articleHeight(for: session.requestIdentity))
                .frame(height: htmlHeight)
                // Replacing the document also revokes its custom resource origin and tasks.
                .id(session.requestIdentity)
            }
        case .result(.website(let url)):
            Link(destination: url) {
                Label(String(localized: "Open lookup website", table: "Learning"), systemImage: "arrow.up.right.square")
            }.font(.callout)
        case .result(.entries(let entries)):
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries, id: \.id) { entry in
                    if entry.headword != session.query { Text(entry.headword).font(.headline) }
                    if let phonetics = entry.phonetics, !phonetics.isEmpty {
                        Text(phonetics.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(entry.senses.enumerated()), id: \.offset) { _, sense in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(sense.partOfSpeech + (sense.labels.isEmpty ? "" : " · " + sense.labels.joined(separator: ", ")))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(sense.definitions.enumerated()), id: \.offset) { index, text in
                                Text(verbatim: "\(index + 1). \(text)").font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    ForEach(entry.examples ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if let url = DictionaryLinkPolicy.externalURL(entry.sourceURL) {
                        Link(entry.sourceName ?? "Wiktionary / Kaikki", destination: url).font(.caption2)
                    }
                    if let licenseURL = entry.licenseURL, let url = DictionaryLinkPolicy.externalURL(licenseURL) {
                        Link(entry.licenseName ?? String(localized: "License", table: "Learning"), destination: url).font(.caption2)
                    } else if let name = entry.licenseName, !name.isEmpty {
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Attribution belongs to the current provider result. Both hosts keep it outside their scroll
/// viewport, including the bundled dictionary's license when a long definition is scrolled.
struct LearningDictionaryAttribution: View {
    @ObservedObject var session: LearningDictionarySession
    var body: some View {
        if case .result(.entries) = session.content, session.selectedSource == .bundled,
           let url = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/") {
            Link(String(localized: "Wiktionary contributors / Kaikki · CC BY-SA 4.0", table: "Learning"), destination: url)
        } else if case .result(.article(let article)) = session.content {
            Text(article.sourceName)
        } else { Text(session.sourceName) }
    }
}
