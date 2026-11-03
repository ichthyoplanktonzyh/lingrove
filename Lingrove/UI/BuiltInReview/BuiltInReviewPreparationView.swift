// Form extracted from Nibomo LingroveNotebookPreparationScreen and CardEditorScreen (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The sheet owns one neutral recipe, authored faces and temporary media. The shared editor
/// changes the recipe; the draft performs three-way generation; only Save admits the scoped
/// writer. Navigation and preview do not write, and edited Cancel retains the discard guard.
struct BuiltInReviewPreparationView: View {
    @ObservedObject var session: BuiltInReviewSession
    @State var draft: BuiltInReviewDraft
    @StateObject private var audio: ReviewAudioPreparation
    @State private var operation: Task<Void, Never>?
    @State private var importingImage = false
    @State private var confirmingDiscard = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    private let original: BuiltInReviewDraftPresentationSnapshot

    init(session: BuiltInReviewSession, draft: BuiltInReviewDraft) {
        self.session = session
        _draft = State(initialValue: draft)
        _audio = StateObject(wrappedValue: ReviewAudioPreparation(speech: session.materialSpeech))
        original = .init(draft)
    }

    private var hasEdits: Bool { BuiltInReviewDraftPresentationSnapshot(draft) != original }
    private var source: (entry: VocabularyEntry, sense: VocabularySense)? { BuiltInReviewSource.value(draft.selection, in: draft.snapshot) }
    private var plan: Binding<ReviewMaterialPlan> {
        Binding(get: { draft.materialPlan }, set: { draft.chooseMaterial($0) })
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
        if case let .editing(_, link) = draft.purpose, source == nil { return link.allowsUnavailableMaterial }
        guard let source else { return false }
        return (try? ReviewMaterialResolver.resolve(entry: source.entry, sense: source.sense, plan: draft.materialPlan)) != nil
    }
    private var busy: Bool { session.isBusy || operation != nil || importingImage || audio.generating != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(source?.entry.expression ?? BuiltInReviewCopy.text("material.retained")).font(.headline).textSelection(.enabled)
                }
                if let source, let store = session.materialStore {
                    ReviewMaterialEditor(plan: plan, entry: source.entry, sense: source.sense, store: store,
                        scope: draft.snapshot, importedImages: $draft.importedImages, importingImage: $importingImage,
                        operation: $operation, prepareAudio: { kind in
                            draft = try await BuiltInReviewMaterialPreparation.prepare(kind, draft: draft, audio: audio, audition: true)
                        })
                } else if let source {
                    Section(BuiltInReviewCopy.text("material.context")) {
                        Picker(BuiltInReviewCopy.text("material.context"), selection: Binding(
                            get: { draft.exampleID }, set: { draft.chooseExample($0) })) {
                            Text(BuiltInReviewCopy.text("material.meaningOnly")).tag(Optional<UUID>.none)
                            ForEach(source.sense.examples) { Text($0.text).tag(Optional($0.id)) }
                        }.accessibilityIdentifier("builtinReview.prepare.context")
                    }
                }
                Section(BuiltInReviewCopy.text("material.customText")) {
                    NavigationLink(value: LingroveReviewEditorField.front) {
                        LingroveReviewTextPreviewRow(title: String(localized: "Front", table: "ReviewCards"), text: draft.front)
                    }.accessibilityIdentifier("builtinReview.prepare.frontRow")
                    NavigationLink(value: LingroveReviewEditorField.back) {
                        LingroveReviewTextPreviewRow(title: String(localized: "Back", table: "ReviewCards"), text: draft.back)
                    }.accessibilityIdentifier("builtinReview.prepare.backRow")
                    if draft.input != draft.generated {
                        Button(BuiltInReviewCopy.text("material.useRecipe")) {
                            if let generated = draft.generated {
                                draft.front = generated.frontText; draft.back = generated.backText; draft.tags = generated.tags
                            }
                        }
                    }
                }
                if let issue = failure ?? session.message { Section { Text(issue).foregroundStyle(.red).textSelection(.enabled) } }
            }.formStyle(.grouped).disabled(busy)
            .navigationTitle(title)
            .navigationDestination(for: LingroveReviewEditorField.self) { field in
                LingroveReviewTextEditorScreen(field: field, text: field == .front ? $draft.front : $draft.back)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", table: "ReviewCards")) {
                        if hasEdits { confirmingDiscard = true } else { discard() }
                    }.keyboardShortcut(.cancelAction).disabled(session.isMutating || importingImage)
                        .accessibilityIdentifier("builtinReview.prepare.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView().controlSize(.small) }
                    Button(saveTitle, action: save).keyboardShortcut("s", modifiers: .command)
                        .disabled(busy || !draft.canSave || !materialIsUsable)
                        .accessibilityIdentifier("builtinReview.prepare.save")
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 560, idealHeight: 700)
        .interactiveDismissDisabled(busy || hasEdits)
        .alert(BuiltInReviewCopy.text("draft.discardTitle"), isPresented: $confirmingDiscard) {
            Button(BuiltInReviewCopy.text("draft.keepEditing"), role: .cancel) { }
                .accessibilityIdentifier("builtinReview.prepare.keepEditing")
            Button(BuiltInReviewCopy.text("draft.discard"), role: .destructive, action: discard)
                .accessibilityIdentifier("builtinReview.prepare.discard")
        }
        .task {
            let media = await session.savedMaterialMedia(draft)
            guard !Task.isCancelled else { return }
            let images = VocabularyContentPolicy.images(draft.materialPlan.layout.customContent)
                .map(ReviewMaterialMediaReference.init(image:))
            let referenced = Set(images + draft.materialPlan.audio.values.map(\.reference))
            for item in media where referenced.contains(item.reference) {
                if !draft.preparedMedia.contains(where: { $0.reference == item.reference }) { draft.preparedMedia.append(item) }
                if let image = item.reference.image, draft.importedImages[image.filename] == nil {
                    draft.importedImages[image.filename] = item.data
                }
            }
        }
        .onDisappear { operation?.cancel(); audio.discard() }
        .accessibilityIdentifier("builtinReview.preparation")
    }

    private func save() {
        guard operation == nil else { return }
        operation = Task {
            defer { operation = nil }
            do {
                var prepared = draft
                for kind in prepared.materialPlan.layout.audioKinds
                    where BuiltInReviewMaterialPreparation.needsAudio(kind, draft: prepared) {
                    prepared = try await BuiltInReviewMaterialPreparation.prepare(kind, draft: prepared, audio: audio, audition: false)
                }
                try Task.checkCancellation()
                prepared = BuiltInReviewMaterialPreparation.stageImages(prepared)
                draft = prepared
                session.save(prepared)
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }

    private func discard() { operation?.cancel(); session.draft = nil; dismiss() }
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
