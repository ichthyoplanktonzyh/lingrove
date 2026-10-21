import SwiftUI

/// The sheet owns one card draft. This editor only rearranges typed content references; shared
/// pure resolution supplies the exact preview that the Anki serializer will later export.
struct VocabularyReviewLayoutEditor: View {
    @ObservedObject var session: AnkiReviewSession
    @ObservedObject var store: VocabularyStore
    @Binding var operation: Task<Void, Never>?
    @State private var back = false
    @State private var previewHeight: CGFloat = 200
    @State private var templateName = ""
    @State private var namingTemplate = false
    @State private var failure: String?

    private var layout: Binding<ReviewLayout> {
        Binding(get: { session.plan.layout ?? .init() }, set: { session.plan.layout = $0; session.plan.fieldOverrides = [:] })
    }
    private var parts: Binding<[ReviewCardPart]> { back ? layout.back : layout.front }

    var body: some View {
        Section {
            TextField(String(localized: "Card name", table: "Vocabulary"), text: Binding(
                get: { session.plan.name ?? "" }, set: { session.plan.name = $0 }))
            HStack {
                Menu(String(localized: "Apply template", table: "Vocabulary")) {
                    Button(String(localized: "Expression → meaning", table: "Vocabulary")) { apply(ReviewLayoutPolicy.preset(0)) }
                    Button(String(localized: "Gap → expression", table: "Vocabulary")) { apply(ReviewLayoutPolicy.preset(1)) }
                    Button(String(localized: "Image → expression", table: "Vocabulary")) { apply(ReviewLayoutPolicy.preset(2)) }
                    Button(String(localized: "Blank card", table: "Vocabulary")) { apply(ReviewLayoutPolicy.preset(3)) }
                    ForEach(store.reviewTemplates) { template in Button(template.name) { apply(template.layout) } }
                }
                Button(String(localized: "Save as template", table: "Vocabulary")) { namingTemplate = true }
            }
            if let current = session.current {
                Picker(String(localized: "Review example", table: "Vocabulary"), selection: Binding(
                    get: { session.plan.exampleID }, set: { session.plan.exampleID = $0; session.plan.fieldOverrides = [:] })) {
                    Text(String(localized: "No context", table: "Vocabulary")).tag(nil as UUID?)
                    ForEach(current.sense.examples) { Text($0.text).lineLimit(1).tag(Optional($0.id)) }
                }
            }
            Picker(String(localized: "Card side", table: "Vocabulary"), selection: $back) {
                Text(String(localized: "Front", table: "Vocabulary")).tag(false)
                Text(String(localized: "Back", table: "Vocabulary")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
        }
        ForEach(parts) { $part in
            Section {
                HStack {
                    Text(part.source.label).fontWeight(.semibold)
                    Spacer()
                    Button { move(part.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(parts.wrappedValue.first?.id == part.id).help(String(localized: "Move up", table: "Vocabulary"))
                    Button { move(part.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(parts.wrappedValue.last?.id == part.id).help(String(localized: "Move down", table: "Vocabulary"))
                    Button(role: .destructive) { parts.wrappedValue.removeAll { $0.id == part.id } } label: { Image(systemName: "trash") }
                        .help(String(localized: "Delete", table: "Vocabulary"))
                }.buttonStyle(.borderless)
                if part.source == .senseImage || part.source == .senseText {
                    Picker(String(localized: "Content source", table: "Vocabulary"), selection: $part.blockID) {
                        Text(String(localized: "Choose…", table: "Vocabulary")).tag(nil as UUID?)
                        ForEach(session.current?.sense.content?.filter { ReviewLayoutPolicy.matches($0,
                            source: part.source) } ?? []) { block in
                            Text(blockLabel(block)).lineLimit(1).tag(Optional(block.id))
                        }
                    }
                    if part.source == .senseImage {
                        Toggle(String(localized: "Show image caption", table: "Vocabulary"), isOn: $part.showCaption)
                    }
                }
                if part.source == .custom, !VocabularyContentPolicy.images(part.content).isEmpty {
                    Toggle(String(localized: "Show image caption", table: "Vocabulary"), isOn: $part.showCaption)
                }
                if part.source == .expressionAudio || part.source == .sentenceAudio {
                    let kind: ReviewAudioKind = part.source == .expressionAudio ? .expression : .sentence
                    Button(String(localized: "Preview audio", table: "Vocabulary")) {
                        guard operation == nil else { return }
                        operation = Task { defer { operation = nil }; await session.prepareAudio(kind, audition: true) }
                    }
                }
            }
            if part.source == .custom {
                VocabularyContentEditor(blocks: $part.content, importedImages: $session.importedImages,
                    store: store, importing: $session.importingImage, pruneImports: false,
                    title: String(localized: "Custom content", table: "Vocabulary"))
            }
        }
        Section {
            Menu {
                ForEach(ReviewContentSource.allCases) { source in
                    Button(source.label) {
                        var part = ReviewCardPart(source: source)
                        if source == .senseImage || source == .senseText {
                            part.blockID = session.current?.sense.content?.first { ReviewLayoutPolicy.matches($0, source: source) }?.id
                        }
                        parts.wrappedValue.append(part)
                    }
                }
            } label: { Label(String(localized: "Add content", table: "Vocabulary"), systemImage: "plus") }
                .disabled(layout.wrappedValue.parts.count >= 64)
        }
        Section(String(localized: "Card preview", table: "Vocabulary")) {
            if let current = session.current, let content = try? ReviewLayoutPolicy.content(
                entry: current.entry, sense: current.sense, plan: session.plan, previewBack: back) {
                let resolved = (back ? content.back : content.front) ?? []
                let html = ReviewLayoutPolicy.preview(resolved)
                DictionaryHTMLView(article: .init(html: html, text: "", sourceName: "Lingrove"), loadResource: { path in
                    guard let ref = VocabularyContentPolicy.images(content.senseContent).first(where: { $0.filename == path })
                    else { return nil }
                    if let bytes = session.importedImages[path] { return .init(data: bytes, mimeType: "image/png") }
                    guard let data = await store.image(ref) else { return nil }
                    return .init(data: data, mimeType: "image/png")
                }, reference: { _ in }, height: $previewHeight).frame(height: previewHeight).id(html)
            } else if let issue = session.validationMessage { Text(issue).foregroundStyle(.secondary) }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .alert(String(localized: "Save as template", table: "Vocabulary"), isPresented: $namingTemplate) {
            TextField(String(localized: "Template name", table: "Vocabulary"), text: $templateName)
            Button(String(localized: "Cancel"), role: .cancel) { }
            Button(String(localized: "Save", table: "Vocabulary")) {
                let snapshot = layout.wrappedValue, name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard operation == nil else { return }
                let images = session.importedImages
                operation = Task {
                    defer { operation = nil }
                    do {
                        try await store.saveTemplate(.init(name: name, layout: ReviewLayoutPolicy.portable(snapshot)),
                            importedImages: images)
                    } catch is CancellationError { } catch { failure = error.localizedDescription }
                }
            }.disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func apply(_ value: ReviewLayout) {
        guard let sense = session.current?.sense else { return }
        layout.wrappedValue = ReviewLayoutPolicy.applying(value, to: sense)
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let index = parts.wrappedValue.firstIndex(where: { $0.id == id }),
            parts.wrappedValue.indices.contains(index + delta) else { return }
        parts.wrappedValue.swapAt(index, index + delta)
    }
    private func blockLabel(_ block: VocabularyContentBlock) -> String {
        switch block.content {
        case let .text(text): text.text
        case let .image(_, caption): caption.isEmpty ? String(localized: "Image", table: "Vocabulary") : caption
        }
    }
}
