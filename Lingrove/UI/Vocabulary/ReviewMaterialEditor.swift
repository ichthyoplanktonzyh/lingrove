import LingroveNotebook
import SwiftUI

/// A preparation sheet owns the bound neutral recipe and temporary bytes. This editor borrows
/// source values and the existing corpus image/template boundary; explicit audio work is supplied
/// by the host adapter. All part controls and native previews are shared by Lingrove and Anki.
struct ReviewMaterialEditor: View {
    @Environment(\.learningInteraction) private var interact
    @Binding var plan: ReviewMaterialPlan
    let entry: VocabularyEntry
    let sense: VocabularySense
    @ObservedObject var store: VocabularyStore
    let scope: VocabularyOperationScope?
    @Binding var importedImages: [String: Data]
    @Binding var importingImage: Bool
    @Binding var operation: Task<Void, Never>?
    var hostedSide: Binding<Bool>?
    var previewFirst = false
    var prepareAudio: (ReviewAudioKind) async throws -> Void
    @State private var localBack = false
    @State private var templateName = ""
    @State private var namingTemplate = false
    @State private var failure: String?

    private var side: Binding<Bool> { hostedSide ?? $localBack }
    private var back: Bool { side.wrappedValue }
    private var layout: Binding<ReviewLayout> { $plan.layout }
    private var parts: Binding<[ReviewCardPart]> { back ? layout.back : layout.front }

    var body: some View {
        if previewFirst { cardPreview }
        Section {
            TextField(String(localized: "Card name", table: "Vocabulary"), text: Binding(
                get: { plan.name ?? "" }, set: { interact(); plan.name = $0 }))
                .accessibilityIdentifier("review.material.name")
            HStack {
                Menu(String(localized: "Apply template", table: "Vocabulary")) {
                    Button(String(localized: "Expression → meaning", table: "Vocabulary")) { apply(ReviewMaterialResolver.preset(0)) }
                    Button(String(localized: "Gap → expression", table: "Vocabulary")) { apply(ReviewMaterialResolver.preset(1)) }
                    Button(String(localized: "Image → expression", table: "Vocabulary")) { apply(ReviewMaterialResolver.preset(2)) }
                    Button(String(localized: "Blank card", table: "Vocabulary")) { apply(ReviewMaterialResolver.preset(3)) }
                    ForEach(store.reviewTemplates) { template in Button(template.name) { apply(template.layout) } }
                }.accessibilityIdentifier("review.material.templates")
                Button(String(localized: "Save as template", table: "Vocabulary")) { interact(); namingTemplate = true }
            }
            Picker(String(localized: "Review example", table: "Vocabulary"), selection: $plan.exampleID) {
                Text(String(localized: "No context", table: "Vocabulary")).tag(nil as UUID?)
                if let selected = plan.exampleID, !sense.examples.contains(where: { $0.id == selected }) {
                    Text(BuiltInReviewCopy.text("material.unavailable")).tag(Optional(selected))
                }
                ForEach(sense.examples) { Text($0.text).lineLimit(1).tag(Optional($0.id)) }
            }.accessibilityIdentifier("builtinReview.prepare.context")
            if hostedSide == nil {
                Picker(String(localized: "Card side", table: "Vocabulary"), selection: side) {
                    Text(String(localized: "Front", table: "Vocabulary")).tag(false)
                    Text(String(localized: "Back", table: "Vocabulary")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("review.material.side")
            }
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
                        ForEach(sense.content?.filter { ReviewMaterialResolver.matches($0, source: part.source) } ?? []) { block in
                            Text(blockLabel(block)).lineLimit(1).tag(Optional(block.id))
                        }
                    }
                }
                if part.source == .senseImage ||
                    part.source == .custom && !VocabularyContentPolicy.images(part.content).isEmpty {
                    Toggle(String(localized: "Show image caption", table: "Vocabulary"), isOn: $part.showCaption)
                }
                if part.source == .expressionAudio || part.source == .sentenceAudio {
                    let kind: ReviewAudioKind = part.source == .expressionAudio ? .expression : .sentence
                    Button(String(localized: "Preview audio", table: "Vocabulary")) { audition(kind) }
                        .accessibilityIdentifier("review.material.audio." + kind.rawValue)
                    if let text = ReviewMaterialResolver.audioText(kind, entry: entry, sense: sense, plan: plan),
                       plan.audio[kind]?.textHash == ReviewMaterialAudio.textHash(text) {
                        Label(BuiltInReviewCopy.text("material.audioReady"), systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if part.source == .custom {
                VocabularyContentEditor(blocks: $part.content, importedImages: $importedImages, store: store,
                    importing: $importingImage, pruneImports: false, title: String(localized: "Custom content", table: "Vocabulary"))
            }
        }
        Section {
            Menu {
                ForEach(ReviewContentSource.allCases) { source in
                    Button(source.label) {
                        var part = ReviewCardPart(source: source)
                        if source == .senseImage || source == .senseText {
                            part.blockID = sense.content?.first { ReviewMaterialResolver.matches($0, source: source) }?.id
                        }
                        parts.wrappedValue.append(part)
                    }
                }
            } label: { Label(String(localized: "Add content", table: "Vocabulary"), systemImage: "plus") }
                .disabled(plan.layout.parts.count >= 64).accessibilityIdentifier("review.material.add")
        }
        .alert(String(localized: "Save as template", table: "Vocabulary"), isPresented: $namingTemplate) {
            TextField(String(localized: "Template name", table: "Vocabulary"), text: $templateName)
            Button(String(localized: "Cancel"), role: .cancel) { }
            Button(String(localized: "Save", table: "Vocabulary")) { saveTemplate() }
                .disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if !previewFirst { cardPreview }
    }

    private var cardPreview: some View {
        Section(String(localized: "Card preview", table: "Vocabulary")) {
            if let resolved = try? ReviewMaterialResolver.resolve(entry: entry, sense: sense, plan: plan, previewBack: back) {
                let selected = back ? resolved.back : resolved.front
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(selected.indices, id: \.self) { index in
                        switch selected[index] {
                        case let .text(text): Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        case let .blocks(blocks): VocabularyContentView(blocks: blocks, store: store, importedImages: importedImages)
                        case let .audio(kind):
                            Button { audition(kind) } label: { Label(kind.label, systemImage: "speaker.wave.2") }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("review.material.preview")
            } else {
                Text(BuiltInReviewCopy.text("material.chooseSource")).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func audition(_ kind: ReviewAudioKind) {
        interact()
        guard operation == nil else { return }
        operation = Task {
            defer { operation = nil }
            do { try await prepareAudio(kind); failure = nil } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }

    private func saveTemplate() {
        guard operation == nil else { return }
        let snapshot = plan.layout, images = importedImages, name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        operation = Task {
            defer { operation = nil }
            do {
                try await store.saveTemplate(.init(name: name, layout: ReviewMaterialResolver.portable(snapshot)),
                    importedImages: images, scope: scope)
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }

    private func apply(_ value: ReviewLayout) { interact(); plan.layout = ReviewMaterialResolver.applying(value, to: sense) }
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
