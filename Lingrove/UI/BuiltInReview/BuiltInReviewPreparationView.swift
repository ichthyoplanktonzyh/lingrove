// Form extracted from Nibomo LingroveNotebookPreparationScreen and CardEditorScreen (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The sheet owns one value draft and an original editable projection for discard protection.
/// Front/back navigation and preview share that draft; only Save hands its unchanged CAS baseline
/// to the existing session writer. Native form and sheet chrome inherit the workspace appearance.
struct BuiltInReviewPreparationView: View {
    @ObservedObject var session: BuiltInReviewSession
    @State var draft: BuiltInReviewDraft
    @State private var preview = false
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss
    private let original: BuiltInReviewDraftPresentationSnapshot

    init(session: BuiltInReviewSession, draft: BuiltInReviewDraft) {
        self.session = session
        _draft = State(initialValue: draft)
        original = .init(draft)
    }

    private var hasEdits: Bool { BuiltInReviewDraftPresentationSnapshot(draft) != original }

    private var source: (entry: VocabularyEntry, sense: VocabularySense)? {
        BuiltInReviewSource.value(draft.selection, in: draft.snapshot)
    }
    private var title: String {
        if case .additionalExercise = draft.purpose { return BuiltInReviewCopy.text("action.addExercise") }
        return BuiltInReviewCopy.text("action.prepare")
    }
    private var saveTitle: String {
        if case .enrollment = draft.purpose { return BuiltInReviewCopy.text("action.enroll") }
        if case .additionalExercise = draft.purpose { return BuiltInReviewCopy.text("action.addExercise") }
        return String(localized: "Save", table: "ReviewCards")
    }
    private var materialIsUsable: Bool {
        if case let .editing(_, link) = draft.purpose {
            if source == nil { return link.allowsUnavailableMaterial }
            let selected = LingroveNotebookCardSource(workspaceId: draft.snapshot.workspaceId,
                notebookId: draft.snapshot.notebookId, entryId: link.source.entryId,
                senseId: link.source.senseId, exampleId: draft.exampleID)
            return LingroveNotebookCardMaterial.resolve(source: selected, snapshot: draft.snapshot) != nil
        }
        return (try? draft.creationDraft()) != nil
    }

    var body: some View {
        NavigationStack {
            LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 0) {
                Form {
                    Section {
                        Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"))
                            .font(.headline).textSelection(.enabled)
                        Text(BuiltInReviewCopy.text("description.preparation")).foregroundStyle(.secondary)
                    }
                    if let source {
                        Section(BuiltInReviewCopy.text("material.context")) {
                            Picker(BuiltInReviewCopy.text("material.context"), selection: Binding(
                                get: { draft.exampleID }, set: { draft.chooseExample($0) })) {
                                Text(BuiltInReviewCopy.text("material.meaningOnly")).tag(Optional<UUID>.none)
                                if let id = draft.exampleID, !source.sense.examples.contains(where: { $0.id == id }) {
                                    Text(BuiltInReviewCopy.text("material.unavailable")).tag(Optional(id))
                                }
                                ForEach(source.sense.examples) { example in Text(example.text).tag(Optional(example.id)) }
                            }.accessibilityIdentifier("builtinReview.prepare.context")
                            Text(BuiltInReviewCopy.text("description.example")).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Section { Label(BuiltInReviewCopy.text("material.retained"), systemImage: "archivebox") }
                    }
                    Section(String(localized: "Text", table: "ReviewCards")) {
                        NavigationLink(value: LingroveReviewEditorField.front) {
                            LingroveReviewTextPreviewRow(title: String(localized: "Front", table: "ReviewCards"), text: draft.front)
                        }.accessibilityIdentifier("builtinReview.prepare.frontRow")
                        NavigationLink(value: LingroveReviewEditorField.back) {
                            LingroveReviewTextPreviewRow(title: String(localized: "Back", table: "ReviewCards"), text: draft.back)
                        }.accessibilityIdentifier("builtinReview.prepare.backRow")
                    }
                    Section {
                        Toggle(BuiltInReviewCopy.text("material.preview"), isOn: $preview)
                            .accessibilityIdentifier("builtinReview.prepare.preview")
                        if preview {
                            BuiltInReviewFace(text: draft.front, images: session.images)
                            Divider()
                            BuiltInReviewFace(text: draft.back, images: session.images)
                        }
                    }
                }.formStyle(.grouped).padding(.top, 8).disabled(session.isBusy)
            }
            .navigationTitle(title)
            .navigationDestination(for: LingroveReviewEditorField.self) { field in
                LingroveReviewTextEditorScreen(field: field, text: field == .front ? $draft.front : $draft.back)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", table: "ReviewCards")) {
                        if hasEdits { confirmingDiscard = true } else { discard() }
                    }
                        .keyboardShortcut(.cancelAction).disabled(session.isMutating)
                        .accessibilityIdentifier("builtinReview.prepare.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if session.isMutating { ProgressView().controlSize(.small) }
                    Button(saveTitle) { session.save(draft) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(session.isBusy || !draft.canSave || !materialIsUsable)
                        .accessibilityIdentifier("builtinReview.prepare.save")
                }
            }
        }
            .frame(minWidth: 540, idealWidth: 620, minHeight: 520, idealHeight: 650)
            .interactiveDismissDisabled(session.isMutating || hasEdits)
            .alert(BuiltInReviewCopy.text("draft.discardTitle"), isPresented: $confirmingDiscard) {
                Button(BuiltInReviewCopy.text("draft.keepEditing"), role: .cancel) { }
                    .accessibilityIdentifier("builtinReview.prepare.keepEditing")
                Button(BuiltInReviewCopy.text("draft.discard"), role: .destructive) { discard() }
                    .accessibilityIdentifier("builtinReview.prepare.discard")
            } message: { Text(BuiltInReviewCopy.text("draft.discardDetail")) }
            .accessibilityIdentifier("builtinReview.preparation")
    }

    private func discard() {
        session.draft = nil
        dismiss()
    }
}

/// The field is navigation state only, as in Nibomo CardEditorDestination.text. Keeping it
/// separate lets the parent retain draft text while the native editor owns its selection.
enum LingroveReviewEditorField: Hashable { case front, back }

/// Extracted CardTextPreviewRow, with the field title injected instead of importing mobile state.
struct LingroveReviewTextPreviewRow: View {
    let title: String
    let text: String

    private var previewText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "Tap to edit", table: "ReviewCards") }
        return trimmed.split(whereSeparator: \.isNewline).map(String.init).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.body).foregroundStyle(.secondary)
            Text(previewText).foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.leading).lineLimit(3)
        }.padding(.vertical, 4)
    }
}

/// The native editor borrows the preparation sheet's binding and owns only field focus.
/// Its native text background resolves with the host; returning to the form retains both edits
/// and the parent's original discard baseline without saving anything.
struct LingroveReviewTextEditorScreen: View {
    let field: LingroveReviewEditorField
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 16) {
            TextEditor(text: $text)
                .font(.body).scrollContentBackground(.hidden).focused($focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
                }
                .accessibilityIdentifier(field == .front ? "builtinReview.prepare.front" : "builtinReview.prepare.back")
        }.padding(.vertical, 16)
            .navigationTitle(String(localized: field == .front ? "Front" : "Back", table: "ReviewCards"))
            .onAppear { focused = true }
    }
}
