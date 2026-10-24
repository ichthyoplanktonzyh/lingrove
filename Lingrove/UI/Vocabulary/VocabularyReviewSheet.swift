import SwiftUI

/// A draft sheet shares the notebook's native grouped form conventions. The known preset uses
/// the same HTML as exported cards, inside the existing no-script/no-network dictionary renderer.
/// Custom note types show mapped fields and keep template execution under Anki's control.
struct VocabularyReviewSheet: View {
    @StateObject private var session: AnkiReviewSession
    @Environment(\.dismiss) private var dismiss
    @State private var back = false
    @State private var gapPreview = false
    @State private var operation: Task<Void, Never>?
    @State private var previewHeight: CGFloat = 180

    init(controller: AnkiReviewController, entry: VocabularyEntry, sense: VocabularySense, cardID: UUID? = nil) {
        _session = StateObject(wrappedValue: AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: cardID))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if session.cardID != nil {
                    VocabularyReviewLayoutEditor(session: session, store: session.controller.store, operation: $operation)
                    destination
                } else {
                preparation
                VocabularyReviewAudioSection(session: session, operation: $operation)
                if session.currentPresetTemplate || session.legacyPresetTemplate { presetPreview } else { mappedPreview }
                }
                if !session.conflicts.isEmpty { conflictSection }
                if let validation = session.validationMessage {
                    Section { Text(validation).font(.caption).foregroundStyle(.secondary) }
                }
                if let message = session.message { Section { Text(message).foregroundStyle(.red).textSelection(.enabled) } }
            }.formStyle(.grouped).disabled(operation != nil || session.busy || session.audio.generating != nil || session.importingImage)
            HStack {
                Button(String(localized: "Review settings", table: "Vocabulary")) {
                    perform {
                        if await session.save() { dismiss(); session.controller.configure?() }
                    }
                }.buttonStyle(.link).disabled(operation != nil || session.busy || session.audio.generating != nil || session.importingImage)
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { operation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", table: "Vocabulary")) { perform { if await session.save() { dismiss() } } }
                    .disabled(operation != nil || session.busy || session.audio.generating != nil || session.importingImage)
                if session.busy || session.loading || session.audio.generating != nil
                    || session.importingImage { ProgressView().controlSize(.small) }
                Button(session.missingNote ? String(localized: "Re-add to Anki", table: "Vocabulary")
                    : session.binding?.noteID == nil ? String(localized: "Add to Anki", table: "Vocabulary")
                    : String(localized: "Update Anki", table: "Vocabulary")) {
                    perform { if await session.send(recreateMissing: session.missingNote) { dismiss() } }
                }.keyboardShortcut(.defaultAction)
                    .disabled(session.busy || operation != nil || session.audio.generating != nil || session.importingImage
                        || session.loading ||
                        session.validationMessage != nil ||
                        session.conflicts.contains { session.keepRemote[$0.id] == nil })
            }.padding()
        }
        .frame(width: 680, height: 690).interactiveDismissDisabled(session.busy || session.importingImage)
        .task(id: session.bindingID) { await session.load() }
        .onDisappear { operation?.cancel(); session.audio.discard() }
        .onChange(of: session.plan.layout) { _, layout in
            let referenced = Set(VocabularyContentPolicy.images(layout?.customContent ?? []).map(\.filename))
            session.importedImages = session.importedImages.filter { referenced.contains($0.key) }
        }
    }

    private var destination: some View {
        Section(String(localized: "Anki connection", table: "Vocabulary")) {
            if let review = session.savedReview, review.bindings.count > 1 {
                Picker(String(localized: "Anki association", table: "Vocabulary"), selection: Binding(
                    get: { session.bindingID }, set: { session.selectBinding($0) })) {
                    Text(String(localized: "Choose…", table: "Vocabulary")).tag(nil as UUID?)
                    ForEach(review.bindings) { binding in
                        Text(binding.profile + " · " + (binding.noteID.map(String.init) ?? "—")).tag(Optional(binding.id))
                    }
                }
            }
            if let catalog = session.catalog {
                Picker(String(localized: "Deck", table: "Vocabulary"), selection: $session.deck) {
                    ForEach(Array(Set(catalog.decks + [session.deck])).sorted(), id: \.self) { Text($0).tag($0) }
                }.disabled(session.binding?.noteID != nil)
                LabeledContent(String(localized: "Anki profile", table: "Vocabulary"), value: catalog.profile)
            } else { TextField(String(localized: "Deck", table: "Vocabulary"), text: $session.deck) }
        }
    }

    /// Claim the UI operation synchronously, before the Task can suspend. This closes the small
    /// double-click window where a second task could replace the first task's cancellation handle.
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard operation == nil else { return }
        operation = Task { defer { operation = nil }; await action() }
    }

    @ViewBuilder private var preparation: some View {
        Section(String(localized: "Review", table: "Vocabulary")) {
            if let review = session.current?.sense.review, review.bindings.count > 1 {
                Picker(String(localized: "Anki association", table: "Vocabulary"), selection: Binding(
                    get: { session.bindingID }, set: { session.selectBinding($0) })) {
                    Text(String(localized: "Choose…", table: "Vocabulary")).tag(nil as UUID?)
                    ForEach(review.bindings) { binding in
                        Text(binding.profile + " · " + (binding.noteID.map(String.init)
                            ?? String(localized: "Ready to send", table: "Vocabulary"))).tag(Optional(binding.id))
                    }
                }
            }
            if let catalog = session.catalog {
                Picker(String(localized: "Deck", table: "Vocabulary"), selection: $session.deck) {
                    ForEach(Array(Set(catalog.decks + [session.deck])).sorted(), id: \.self) { Text($0).tag($0) }
                }.disabled(session.binding?.noteID != nil)
                LabeledContent(String(localized: "Anki profile", table: "Vocabulary"), value: catalog.profile)
            } else {
                TextField(String(localized: "Deck", table: "Vocabulary"), text: $session.deck)
                    .disabled(session.binding?.noteID != nil)
            }
            LabeledContent(String(localized: "Note type", table: "Vocabulary"), value: session.model)
            if session.model == AnkiReviewPolicy.presetName, !session.currentPresetTemplate, !session.loading {
                Button(String(localized: "Update Lingrove template", table: "Vocabulary")) {
                    perform { await session.updateTemplate() }
                }
            }
            if let current = session.current {
                Picker(String(localized: "Review example", table: "Vocabulary"), selection: Binding(
                    get: { session.plan.exampleID }, set: { id in
                        session.plan.exampleID = id
                        if !session.canGap { session.plan.gap = false }
                        if id == nil { session.plan.audioKinds?.remove(.sentence) }
                        session.plan.fieldOverrides = [:]
                    })) {
                    Text(String(localized: "No context", table: "Vocabulary")).tag(nil as UUID?)
                    ForEach(current.sense.examples) { Text($0.text).lineLimit(1).tag(Optional($0.id)) }
                }
                if let preserved = current.sense.review?.preservedPlans, !preserved.isEmpty {
                    Menu(String(localized: "Preserved review plans", table: "Vocabulary")) {
                        ForEach(preserved) { plan in
                            Button(plan.answer ?? current.sense.displayTitle) { session.restorePlan(plan) }
                        }
                    }
                }
            }
            TextField(String(localized: "Review answer", table: "Vocabulary"), text: Binding(
                get: { session.answer }, set: { session.plan.answer = $0 }), axis: .vertical).lineLimit(2...5)
            if session.model == AnkiReviewPolicy.presetName {
                HStack {
                    Toggle(String(localized: "Recognition card", table: "Vocabulary"), isOn: $session.plan.recognition)
                        .disabled(session.hasExistingCard(.recognition))
                    Toggle(String(localized: "Gap card", table: "Vocabulary"), isOn: $session.plan.gap)
                        .disabled(!session.canGap && !session.plan.gap ||
                            session.hasExistingCard(.gapPrompt))
                }
                if session.binding?.noteID != nil {
                    Text(String(localized: "Manage existing card types in Anki.", table: "Vocabulary"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "Card types follow the Anki template.", table: "Vocabulary"))
                    .font(.caption).foregroundStyle(.secondary)
                if session.mapping[.gapPrompt] != nil, session.mapping[.gapAnswer] != nil {
                    Toggle(String(localized: "Gap card", table: "Vocabulary"), isOn: $session.plan.gap)
                        .disabled(!session.canGap && !session.plan.gap || session.hasExistingCard(.gapPrompt))
                    if session.hasExistingCard(.gapPrompt) {
                        Text(String(localized: "Manage existing card types in Anki.", table: "Vocabulary"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !session.canGap {
                Text(String(localized: "A gap card requires valid expression positions in an example.", table: "Vocabulary"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(String(localized: "Include notes", table: "Vocabulary"), isOn: $session.plan.includeNotes)
            Toggle(String(localized: "Include sense explanation", table: "Vocabulary"), isOn: Binding(
                get: { session.plan.includeSenseContent == true }, set: { session.plan.includeSenseContent = $0 }))
            Toggle(String(localized: "Include AI explanation", table: "Vocabulary"), isOn: $session.plan.includeExplanation)
            if !session.plan.fieldOverrides.isEmpty {
                Button(String(localized: "Use notebook fields again", table: "Vocabulary")) { session.plan.fieldOverrides = [:] }
            }
        }
    }

    private var presetPreview: some View {
        Section(String(localized: "Card preview", table: "Vocabulary")) {
            HStack {
                Picker(String(localized: "Card type", table: "Vocabulary"), selection: $gapPreview) {
                    Text(String(localized: "Recognition card", table: "Vocabulary")).tag(false)
                    Text(String(localized: "Gap card", table: "Vocabulary")).tag(true)
                }.labelsHidden().pickerStyle(.segmented)
                Picker(String(localized: "Card side", table: "Vocabulary"), selection: $back) {
                    Text(String(localized: "Front", table: "Vocabulary")).tag(false)
                    Text(String(localized: "Back", table: "Vocabulary")).tag(true)
                }.labelsHidden().pickerStyle(.segmented)
            }
            if let content = session.content, let fields = try? AnkiReviewPolicy.fields(content: content,
                identity: session.binding?.originSenseID ?? session.senseID, mapping: AnkiReviewPolicy.presetMapping,
                overrides: session.plan.fieldOverrides, audio: session.audioFieldsForPreview) {
                let enabled = gapPreview ? !(fields[ReviewField.gapPrompt.rawValue] ?? "").isEmpty
                    : !(fields[ReviewField.recognition.rawValue] ?? "").isEmpty
                if enabled {
                    let html = AnkiNoteTemplate.preview(fields: fields, gap: gapPreview, back: back, css: session.presetCSS,
                        legacy: session.legacyPresetTemplate)
                    DictionaryHTMLView(article: .init(html: html, text: "", sourceName: "Lingrove"),
                        loadResource: { path in
                            guard let image = VocabularyContentPolicy.images(content.senseContent).first(where: { $0.filename == path }),
                                  let data = await session.controller.store.image(image) else { return nil }
                            return .init(data: data, mimeType: "image/png")
                        }, reference: { _ in }, height: $previewHeight)
                        .frame(height: previewHeight).id(html)
                } else { Text(String(localized: "This card is not enabled.", table: "Vocabulary")) }
            }
        }
    }

    private var mappedPreview: some View {
        Section(String(localized: "Mapped fields", table: "Vocabulary")) {
            if let content = session.content, let fields = try? AnkiReviewPolicy.fields(content: content,
                identity: session.binding?.originSenseID ?? session.senseID, mapping: session.mapping,
                overrides: session.plan.fieldOverrides, audio: session.audioFieldsForPreview) {
                ForEach(fields.keys.sorted(), id: \.self) { field in
                    LabeledContent(field) { Text(fields[field] ?? "").textSelection(.enabled) }
                }
            }
        }
    }

    private var conflictSection: some View {
        Section(String(localized: "Anki fields changed", table: "Vocabulary")) {
            ForEach(session.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    Text(conflict.id).fontWeight(.semibold)
                    Text("Lingrove: " + conflict.local).font(.callout).textSelection(.enabled)
                    Text("Anki: " + conflict.remote).font(.callout).textSelection(.enabled)
                    Picker(String(localized: "Keep version", table: "Vocabulary"), selection: Binding(
                        get: { session.keepRemote[conflict.id] }, set: { session.keepRemote[conflict.id] = $0 })) {
                        Text(String(localized: "Choose…", table: "Vocabulary")).tag(nil as Bool?)
                        Text("Anki").tag(Optional(true))
                        Text("Lingrove").tag(Optional(false))
                    }
                }
            }
        }
    }
}
