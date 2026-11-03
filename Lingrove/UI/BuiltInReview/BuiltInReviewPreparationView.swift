// Form extracted from Nibomo LingroveNotebookPreparationScreen and CardEditorScreen (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// A native adaptation of Nibomo’s material form and separate front/back editor screens. This
/// sheet owns the original value draft, including its CAS baseline. Navigation, preview and
/// Cancel do not write; Save passes that same draft to the existing session/IO writer.
struct BuiltInReviewPreparationView: View {
    @ObservedObject var session: BuiltInReviewSession
    @State var draft: BuiltInReviewDraft
    @State private var preview = false
    @Environment(\.dismiss) private var dismiss

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
                        Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource")).font(.headline)
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
                }.formStyle(.grouped).disabled(session.isBusy)
            }
            .navigationTitle(title)
            .navigationDestination(for: LingroveReviewEditorField.self) { field in
                LingroveReviewTextEditorScreen(field: field, text: field == .front ? $draft.front : $draft.back)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", table: "ReviewCards")) { session.draft = nil; dismiss() }
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
        }.frame(width: 620, height: 650).tint(.orange).preferredColorScheme(.dark)
            .interactiveDismissDisabled(session.isMutating)
            .accessibilityIdentifier("builtinReview.preparation")
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

/// Extracted CardTextEditorScreen’s text area. The native TextEditor edits a binding owned by
/// the preparation sheet; it owns focus only. Media import/telemetry/mobile store are omitted
/// because this screen edits already saved corpus material rather than creating remote assets.
struct LingroveReviewTextEditorScreen: View {
    let field: LingroveReviewEditorField
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 16) {
            TextEditor(text: $text)
                .font(.body).scrollContentBackground(.hidden).focused($focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityIdentifier(field == .front ? "builtinReview.prepare.front" : "builtinReview.prepare.back")
        }.padding(.vertical, 16)
            .navigationTitle(String(localized: field == .front ? "Front" : "Back", table: "ReviewCards"))
            .onAppear { focused = true }
    }
}
