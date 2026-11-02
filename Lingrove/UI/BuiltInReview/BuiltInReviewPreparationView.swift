import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// One sheet owns a value copy of its original preparation. Typing and previewing do not write
/// the corpus or enroll a sense. Save hands that exact scope, group, Card and link back to IO;
/// Cancel, sheet dismissal and repository invalidation simply discard the copy.
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
        return BuiltInReviewCopy.text("action.save")
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.title2.weight(.semibold))
                Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource")).font(.headline)
                Text(BuiltInReviewCopy.text("description.preparation")).font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let source {
                        Picker(BuiltInReviewCopy.text("material.context"), selection: Binding(
                            get: { draft.exampleID }, set: { draft.chooseExample($0) })) {
                            Text(BuiltInReviewCopy.text("material.meaningOnly")).tag(Optional<UUID>.none)
                            if let id = draft.exampleID, !source.sense.examples.contains(where: { $0.id == id }) {
                                Text(BuiltInReviewCopy.text("material.unavailable")).tag(Optional(id))
                            }
                            ForEach(source.sense.examples) { example in
                                Text(example.text).lineLimit(2).tag(Optional(example.id))
                            }
                        }.accessibilityIdentifier("builtinReview.prepare.context")
                        Text(BuiltInReviewCopy.text("description.example")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label(BuiltInReviewCopy.text("material.retained"), systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                    }
                    editor("field.prompt", text: $draft.front, minimumHeight: 90, identifier: "builtinReview.prepare.front")
                    editor("field.answer", text: $draft.back, minimumHeight: 120, identifier: "builtinReview.prepare.back")
                    Toggle(BuiltInReviewCopy.text("material.preview"), isOn: $preview)
                        .accessibilityIdentifier("builtinReview.prepare.preview")
                    if preview {
                        GroupBox(BuiltInReviewCopy.text("material.preview")) {
                            VStack(alignment: .leading, spacing: 16) {
                                BuiltInReviewFace(text: draft.front, images: [])
                                Divider()
                                BuiltInReviewFace(text: draft.back, images: [])
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(24).disabled(session.isBusy)
            }
            Divider()
            HStack {
                Button(BuiltInReviewCopy.text("action.cancel")) { session.draft = nil; dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("builtinReview.prepare.cancel")
                Spacer()
                if session.isMutating { ProgressView().controlSize(.small) }
                Button(saveTitle) { session.save(draft) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(session.isBusy || !draft.canSave || !materialIsUsable)
                    .accessibilityIdentifier("builtinReview.prepare.save")
            }.padding(20)
        }.frame(width: 620, height: 650).background(Color(nsColor: .windowBackgroundColor))
            .accessibilityIdentifier("builtinReview.preparation")
    }

    private func editor(_ key: String, text: Binding<String>, minimumHeight: CGFloat, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BuiltInReviewCopy.text(key)).font(.headline)
            TextEditor(text: text).font(.body).frame(minHeight: minimumHeight)
                .padding(5).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                .accessibilityLabel(BuiltInReviewCopy.text(key)).accessibilityIdentifier(identifier)
        }
    }
}
