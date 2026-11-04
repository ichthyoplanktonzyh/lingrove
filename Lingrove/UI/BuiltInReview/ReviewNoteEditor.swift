import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// Native note editing is separate from the shared type editor: changing an example or a
/// custom field affects this note, while editing the type affects every note using it.
struct ReviewNoteEditor: View {
    @ObservedObject var session: BuiltInReviewSession
    @State var draft: ReviewNoteEditorDraft
    @State private var confirmingDiscard = false
    private var changed: Bool { draft.note != draft.expected }
    private var sense: VocabularySense? {
        draft.scope.document.entries.flatMap(\.senses).first { $0.id == draft.note.senseID }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let sense {
                    Picker(ReviewField.sentence.label, selection: $draft.note.exampleID) {
                        Text("—").tag(Optional<UUID>.none)
                        ForEach(sense.examples) { Text($0.text).tag(Optional($0.id)) }
                    }
                }
                ForEach(draft.type.fields.filter { $0.source == .custom }) { field in
                    Section(field.name) {
                        TextEditor(text: Binding(get: { draft.note.customFields[field.id.uuidString.lowercased()] ?? "" },
                            set: { draft.note.customFields[field.id.uuidString.lowercased()] = $0 }))
                            .font(.system(.body, design: .monospaced)).frame(minHeight: 80)
                    }
                }
                if let message = session.message { Text(message).foregroundStyle(.red) }
            }.formStyle(.grouped).disabled(session.isBusy)
                .navigationTitle(BuiltInReviewCopy.noteTypeName(draft.type))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            if changed { confirmingDiscard = true } else { session.noteDraft = nil }
                        }.keyboardShortcut(.cancelAction).disabled(session.isMutating)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save", table: "Vocabulary")) { session.saveNote(draft) }
                            .disabled(!changed || session.isBusy).keyboardShortcut("s", modifiers: .command)
                    }
                }
        }.frame(minWidth: 560, minHeight: 360)
            .interactiveDismissDisabled(changed || session.isBusy)
            .alert(BuiltInReviewCopy.text("draft.discardTitle"), isPresented: $confirmingDiscard) {
                Button(BuiltInReviewCopy.text("draft.keepEditing"), role: .cancel) {}
                Button(BuiltInReviewCopy.text("draft.discard"), role: .destructive) { session.noteDraft = nil }
            }
    }
}
