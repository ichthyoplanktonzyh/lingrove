import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The editor owns a definition draft, while the session owns its atomic scoped save. HTML/CSS
/// editing and native preview share one resolver with practice/export. A future design model can
/// replace this layout and the default CSS without changing note identities or scheduling.
struct ReviewNoteTypeEditor: View {
    @ObservedObject var session: BuiltInReviewSession
    @State var draft: ReviewNoteTypeEditorDraft
    @State private var selectedTemplate: UUID
    @State private var tab = 0
    @State private var sampleID: UUID?
    @State private var images: [String: Data] = [:]
    @State private var confirmingDiscard = false
    private let original: ReviewNoteType

    init(session: BuiltInReviewSession, draft: ReviewNoteTypeEditorDraft) {
        self.session = session; self.draft = draft; original = draft.type
        _selectedTemplate = State(initialValue: draft.type.templates[0].id)
        _sampleID = State(initialValue: draft.scope.document.collectedEntries.first?.senses.first?.id)
    }
    private var changed: Bool { draft.type != original || draft.makeDefault }
    private var validation: String? {
        do { try ReviewTemplateRenderer.validate(draft.type); return nil }
        catch { return ReviewNoteEditorCopy.message(error) }
    }
    private var source: (VocabularyEntry, VocabularySense)? {
        for entry in draft.scope.document.collectedEntries {
            if let sense = entry.senses.first(where: { $0.id == sampleID }) { return (entry, sense) }
        }
        return nil
    }
    private var preview: ReviewRenderedCard? {
        guard let template = draft.type.templates.first(where: { $0.id == selectedTemplate }), let (entry, sense) = source else { return nil }
        let note = ReviewNote(noteTypeID: draft.type.id, entryID: entry.id, senseID: sense.id,
            exampleID: sense.examples.sorted { $0.createdAt < $1.createdAt }.first?.id)
        guard let fields = try? ReviewNoteProjection.fields(note: note, type: draft.type, entry: entry, sense: sense) else { return nil }
        return try? ReviewTemplateRenderer.render(type: draft.type, template: template, fields: fields)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                Divider()
                presetGalleryBar
                Divider()
                HSplitView {
                    controls.frame(minWidth: 340, idealWidth: 430)
                    previewColumn.frame(minWidth: 340, idealWidth: 540)
                }
                if let issue = validation ?? session.message {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(issue)
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                }
            }
            .disabled(session.isBusy)
            .navigationTitle(String(localized: "Card templates", table: "Vocabulary"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        if changed { confirmingDiscard = true } else { session.noteTypeDraft = nil }
                    }.keyboardShortcut(.cancelAction).disabled(session.isMutating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", table: "Vocabulary")) { session.saveNoteType(draft) }
                        .disabled(validation != nil || !changed || session.isBusy)
                        .keyboardShortcut("s", modifiers: .command)
                        .accessibilityIdentifier("review.noteType.save")
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 1080, minHeight: 660, idealHeight: 780)
        .interactiveDismissDisabled(changed || session.isBusy)
        .alert(BuiltInReviewCopy.text("draft.discardTitle"), isPresented: $confirmingDiscard) {
            Button(BuiltInReviewCopy.text("draft.keepEditing"), role: .cancel) {}
            Button(BuiltInReviewCopy.text("draft.discard"), role: .destructive) { session.noteTypeDraft = nil }
        }
        .task(id: sampleID) {
            images = [:]
            guard let (_, sense) = source, let store = session.materialStore else { return }
            for reference in VocabularyContentPolicy.images(sense.content ?? []) {
                let bytes = await store.image(reference, scope: draft.scope)
                guard !Task.isCancelled else { return }
                images[reference.filename] = bytes
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                .font(.title3)
                .foregroundStyle(LingroveBrand.accent)
            TextField(String(localized: "Template name", table: "Vocabulary"), text: $draft.type.name)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
            Button {
                draft.duplicate()
                selectedTemplate = draft.type.templates[0].id
            } label: {
                Label(String(localized: "Copy", table: "Vocabulary"), systemImage: "plus.square.on.square")
            }
            .buttonStyle(.bordered)
            Toggle(String(localized: "Default cards", table: "Vocabulary"), isOn: $draft.makeDefault)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var presetGalleryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ReviewNoteDefaults.presets) { preset in
                    let isSelected = ReviewNoteDefaults.matches(preset, type: draft.type)
                    Button {
                        guard !isSelected else { return }
                        draft.choosePreset(preset)
                        if let first = draft.type.templates.first { selectedTemplate = first.id }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(preset.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 4)
                                Text(preset.badge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isSelected ? LingroveBrand.accent : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? LingroveBrand.accent.opacity(0.16) : Color(nsColor: .windowBackgroundColor))
                                    )
                            }
                            Text(preset.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(width: 225, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? LingroveBrand.accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected ? LingroveBrand.accent.opacity(0.65) : Color(nsColor: .separatorColor).opacity(0.45),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("review.noteType.preset." + preset.id)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var previewColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(BuiltInReviewCopy.text("material.preview"), selection: $sampleID) {
                    ForEach(draft.scope.document.collectedEntries) { entry in
                        ForEach(entry.senses) { sense in
                            Text(entry.expression + " · " + sense.meaning).tag(Optional(sense.id))
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Picker(String(localized: "Card side", table: "Vocabulary"), selection: Binding(
                    get: { tab == 1 ? 1 : 0 },
                    set: { tab = $0 }
                )) {
                    Text(BuiltInReviewCopy.text("field.prompt")).tag(0)
                    Text(BuiltInReviewCopy.text("field.answer")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if let preview {
                ReviewNoteWebView(html: tab == 0 ? preview.frontHTML : preview.backHTML, css: preview.css, images: images)
                    .padding(16)
                    .background(Color(nsColor: .underPageBackgroundColor).opacity(0.25))
                    .accessibilityIdentifier("review.noteType.preview")
            } else {
                ContentUnavailableView(BuiltInReviewCopy.text("material.preview"), systemImage: "rectangle.stack")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Picker(String(localized: "Card templates", table: "Vocabulary"), selection: $selectedTemplate) {
                    ForEach(draft.type.templates) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                Button {
                    let template = ReviewCardTemplate(name: String(localized: "New card", table: "Vocabulary"),
                        front: "{{Expression}}", back: "{{FrontSide}}<hr id=answer>{{Meaning}}")
                    draft.type.templates.append(template); selectedTemplate = template.id
                } label: { Image(systemName: "plus") }
                    .disabled(draft.type.templates.count >= 16).help(String(localized: "Add card", table: "Vocabulary"))
            }
            if let index = draft.type.templates.firstIndex(where: { $0.id == selectedTemplate }) {
                HStack {
                    TextField(String(localized: "Card name", table: "Vocabulary"), text: $draft.type.templates[index].name)
                    Toggle(BuiltInReviewCopy.text("status.active"), isOn: $draft.type.templates[index].enabled)
                }
                Picker(String(localized: "Card side", table: "Vocabulary"), selection: $tab) {
                    Text(BuiltInReviewCopy.text("field.prompt")).tag(0)
                    Text(BuiltInReviewCopy.text("field.answer")).tag(1)
                    Text(verbatim: "CSS").tag(2)
                }.pickerStyle(.segmented)
                TextEditor(text: Binding(get: {
                    tab == 0 ? draft.type.templates[index].front : tab == 1 ? draft.type.templates[index].back : draft.type.css
                }, set: { value in
                    if tab == 0 { draft.type.templates[index].front = value }
                    else if tab == 1 { draft.type.templates[index].back = value }
                    else { draft.type.css = value }
                })).font(.system(.body, design: .monospaced)).frame(minHeight: 170)
                    .accessibilityIdentifier("review.noteType.code")
            }
            DisclosureGroup(String(localized: "Field mapping", table: "Vocabulary")) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($draft.type.fields) { $field in
                            HStack {
                                TextField(String(localized: "Template name", table: "Vocabulary"), text: $field.name)
                                Picker(String(localized: "Content source", table: "Vocabulary"), selection: $field.source) {
                                    ForEach(ReviewNoteEditorCopy.sources, id: \.self) { Text(ReviewNoteEditorCopy.label($0)).tag($0) }
                                }.labelsHidden()
                            }
                        }
                        Button(String(localized: "Add content", table: "Vocabulary")) {
                            draft.type.fields.append(.init(name: "Field" + String(draft.type.fields.count + 1), source: .custom))
                        }.disabled(draft.type.fields.count >= 64)
                    }
                }.frame(maxHeight: 180)
            }
        }.padding(16)
    }
}

/// Host-localized finite source labels and errors keep parser implementation details out of UI.
enum ReviewNoteEditorCopy {
    static let sources: [ReviewNoteField.Source] = [.expression, .meaning, .sentence, .translation, .notes, .richContent, .custom]
    static func label(_ source: ReviewNoteField.Source) -> String {
        switch source {
        case .expression: ReviewField.expression.label
        case .meaning: ReviewField.meaning.label
        case .sentence: ReviewField.sentence.label
        case .translation: ReviewField.translation.label
        case .notes: ReviewField.notes.label
        case .richContent: String(localized: "Content source", table: "Vocabulary")
        case .custom: String(localized: "Custom content", table: "Vocabulary")
        }
    }
    static func message(_ error: any Error) -> String {
        if case let ReviewTemplateError.unknownField(name) = error {
            return BuiltInReviewCopy.text("template.invalid") + " " + name
        }
        return BuiltInReviewCopy.text("template.invalid")
    }
}
