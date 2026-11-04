import LingroveNotebook
import SwiftUI

/// Sending a shared Note exposes only its type, deck and actual card preview. It uses the same
/// renderer as built-in review; no per-card content construction is required on this path.
struct VocabularyNoteAnkiSheet: View {
    private let onSent: () -> Void
    @StateObject private var session: NoteAnkiSession
    @Environment(\.dismiss) private var dismiss
    @State private var answer = false
    @State private var templateID: UUID?
    @State private var operation: Task<Void, Never>?
    init(controller: AnkiReviewController, selection: VocabularySelection, onSent: @escaping () -> Void = {}) {
        self.onSent = onSent
        _session = StateObject(wrappedValue: NoteAnkiSession(controller: controller, selection: selection))
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(String(localized: "Note type", table: "Vocabulary"), selection: $session.typeID) {
                    ForEach(session.types) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(String(localized: "Deck", table: "Vocabulary"), selection: $session.deck) {
                    ForEach(session.catalog?.decks ?? [session.deck], id: \.self) { Text($0).tag($0) }
                }
                if let profile = session.catalog?.profile {
                    LabeledContent(String(localized: "Anki profile", table: "Vocabulary"), value: profile)
                }
                if let material = session.material {
                    Picker(String(localized: "Card templates", table: "Vocabulary"), selection: $templateID) {
                        ForEach(material.type.templates.filter(\.enabled)) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                ForEach(session.conflicts) { field in
                    Section(field.id) {
                        Text("Lingrove: " + field.local).textSelection(.enabled)
                        Text("Anki: " + field.remote).textSelection(.enabled)
                        Picker(
                            String(localized: "Keep version", table: "Vocabulary"),
                            selection: Binding(
                                get: { session.choices[field.id] }, set: { session.choices[field.id] = $0 })
                        ) {
                            Text(String(localized: "Choose…", table: "Vocabulary")).tag(Optional<Bool>.none)
                            Text("Anki").tag(Optional(true))
                            Text("Lingrove").tag(Optional(false))
                        }
                    }
                }
                if let message = session.message { Text(message).foregroundStyle(.red) }
            }.formStyle(.grouped).disabled(session.busy).frame(maxHeight: session.conflicts.isEmpty ? 210 : 350)
            Picker(String(localized: "Card side", table: "Vocabulary"), selection: $answer) {
                Text(BuiltInReviewCopy.text("field.prompt")).tag(false)
                Text(BuiltInReviewCopy.text("field.answer")).tag(true)
            }.pickerStyle(.segmented).padding(.horizontal)
            if let material = session.material,
                let template = material.type.templates.first(where: { $0.id == templateID && $0.enabled }),
                let rendered = try? ReviewTemplateRenderer.render(
                    type: material.type, template: template,
                    fields: material.export.fields.filter { $0.key != "LingroveNoteID" }) {
                ReviewNoteWebView(
                    html: answer ? rendered.backHTML : rendered.frontHTML, css: rendered.css, images: session.images)
            } else {
                Spacer()
            }
            HStack {
                Button(String(localized: "Cancel")) {
                    operation?.cancel()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if session.busy { ProgressView().controlSize(.small) }
                Button(
                    session.hasAssociation
                        ? String(localized: "Update Anki", table: "Vocabulary")
                        : String(localized: "Add to Anki", table: "Vocabulary")
                ) {
                    operation = Task {
                        if await session.send() {
                            onSent()
                            dismiss()
                        }
                        operation = nil
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(
                        session.material == nil || session.busy || operation != nil
                            || session.conflicts.contains { session.choices[$0.id] == nil })
            }.padding()
        }.frame(width: 720, height: 720)
            .interactiveDismissDisabled(session.busy)
            .task {
                await session.load()
                templateID = session.material?.type.templates.first(where: \.enabled)?.id
            }
            .onChange(of: session.typeID) { _, _ in
                operation?.cancel()
                operation = Task {
                    await session.preview()
                    templateID = session.material?.type.templates.first(where: \.enabled)?.id
                    operation = nil
                }
            }
            .onDisappear { operation?.cancel() }
    }
}
