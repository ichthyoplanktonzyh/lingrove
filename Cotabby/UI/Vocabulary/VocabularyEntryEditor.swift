import SwiftUI

/// A sheet owns a value draft. Cancel leaves the store untouched; Save awaits durable storage
/// before dismissing. Editing an example's text re-anchors expression highlight spans through
/// `VocabularyPolicy.reconciledRanges` while preserving existing translations and contextual meanings.
struct VocabularyEntryEditor: View {
    @ObservedObject var store: VocabularyStore
    private let baseline: VocabularyEntry
    private let senseID: UUID
    @State private var draft: VocabularyEntry
    @State private var tagList: [String]
    @State private var newTagInput = ""
    @State private var saving = false
    @State private var importedImages: [String: Data] = [:]
    @State private var importingImage = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(entry: VocabularyEntry, store: VocabularyStore, senseID: UUID? = nil) {
        self.store = store
        baseline = entry
        let resolvedSenseID = senseID ?? entry.senses.first?.id ?? UUID()
        self.senseID = resolvedSenseID
        _draft = State(initialValue: entry)
        _tagList = State(initialValue: entry.senses.first { $0.id == resolvedSenseID }?.tags ?? [])
    }

    private var suggestedTags: [String] {
        let existing = Set(tagList)
        return Array(Set(store.entries.flatMap { $0.senses.flatMap(\.tags) }))
            .filter { !existing.contains($0) }
            .sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            Form {
                if let sense = draft.senses.firstIndex(where: { $0.id == senseID }) {
                    Section {
                        TextField(String(localized: "Expression", table: "Vocabulary"), text: $draft.expression)
                            .onChange(of: draft.expression) { _, updatedExpression in
                                for index in draft.senses[sense].examples.indices {
                                    draft.senses[sense].examples[index].ranges = VocabularyPolicy.reconciledRanges(
                                        in: draft.senses[sense].examples[index].text,
                                        expression: updatedExpression,
                                        dictionaryForm: draft.dictionaryForm
                                    )
                                }
                            }
                        TextField(String(localized: "Dictionary form", table: "Vocabulary"), text: $draft.dictionaryForm)
                        TextField(String(localized: "Core meaning", table: "Vocabulary"),
                            text: $draft.senses[sense].meaning, axis: .vertical)
                        TextField(String(localized: "Notes", table: "Vocabulary"), text: $draft.senses[sense].note, axis: .vertical)
                    }

                    Section(String(localized: "Tags", table: "Vocabulary")) {
                        tagEditorSection
                    }

                    VocabularyContentEditor(blocks: Binding(
                        get: { draft.senses[sense].content ?? [] }, set: { draft.senses[sense].content = $0 }),
                        importedImages: $importedImages, store: store, importing: $importingImage)

                    ForEach($draft.senses[sense].examples) { $example in
                        Section(String(localized: "Example sentence", table: "Vocabulary")) {
                            TextField(String(localized: "Original text", table: "Vocabulary"), text: $example.text, axis: .vertical)
                                .onChange(of: example.text) { _, updatedText in
                                    example.ranges = VocabularyPolicy.reconciledRanges(
                                        in: updatedText,
                                        expression: draft.expression,
                                        dictionaryForm: draft.dictionaryForm
                                    )
                                }
                            TextField(String(localized: "Translation", table: "Vocabulary"), text: $example.translation, axis: .vertical)
                            TextField(String(localized: "Meaning in this context", table: "Vocabulary"),
                                text: $example.meaning, axis: .vertical)
                            Picker(String(localized: "Context type", table: "Vocabulary"), selection: $example.completeness) {
                                Text(String(localized: "Example sentence", table: "Vocabulary"))
                                    .tag(VocabularyExample.Completeness.sentence)
                                Text(String(localized: "Context fragment", table: "Vocabulary"))
                                    .tag(VocabularyExample.Completeness.fragment)
                            }
                            HStack {
                                Spacer()
                                Button(String(localized: "Delete", table: "Vocabulary"), role: .destructive) {
                                    let id = example.id
                                    draft.senses[sense].examples.removeAll { $0.id == id }
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    Section {
                        Button {
                            draft.senses[sense].examples.append(VocabularyExample(id: UUID(), text: "", translation: "",
                                translationLanguage: draft.senses[sense].meaningLanguage, ranges: [], completeness: .fragment,
                                meaning: "", createdAt: Date()))
                        } label: { Label(String(localized: "Add example", table: "Vocabulary"), systemImage: "plus") }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            Divider()
            editorFooter
        }
        .frame(width: 680, height: 660)
        .interactiveDismissDisabled(saving)
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.expression.isEmpty ? baseline.expression : draft.expression)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(draft.language.label)
                    Text("·")
                    Text(draft.kind.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var tagEditorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !tagList.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(tagList, id: \.self) { tag in
                        RemovableTagChip(text: "#" + tag) {
                            tagList.removeAll { $0 == tag }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(String(localized: "Tags", table: "Vocabulary"), text: $newTagInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitPendingTags() }
                    .onChange(of: newTagInput) { _, value in
                        if value.contains(",") || value.contains("，") {
                            commitPendingTags()
                        }
                    }
                if !newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        commitPendingTags()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(CotabbyBrand.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !suggestedTags.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(suggestedTags.prefix(8), id: \.self) { suggestion in
                        AddableTagChip(text: suggestion) {
                            appendTag(suggestion)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var editorFooter: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button(String(localized: "Save", table: "Vocabulary")) {
                commitPendingTags()
                saving = true
                var value = draft
                guard let sense = value.senses.firstIndex(where: { $0.id == senseID }) else { saving = false; return }
                value.senses[sense].tags = Array(Set(tagList)).sorted()
                Task {
                    if await store.update(value, basedOn: baseline, importedImages: importedImages) {
                        dismiss()
                    } else { failure = store.errorMessage }
                    saving = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(saving || importingImage || draft.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .disabled(draft.senses.first { $0.id == senseID }?.examples.contains {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func commitPendingTags() {
        let tokens = newTagInput
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
        for token in tokens {
            appendTag(token)
        }
        newTagInput = ""
    }

    private func appendTag(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !cleaned.isEmpty, !tagList.contains(cleaned) else { return }
        tagList.append(cleaned)
    }
}
