import SwiftUI

/// A sheet owns a value draft. Cancel leaves the store untouched; Save awaits durable storage
/// before dismissing. Example edits clear obsolete ranges instead of highlighting unrelated text.
struct VocabularyEntryEditor: View {
    @ObservedObject var store: VocabularyStore
    private let baseline: VocabularyEntry
    @State private var draft: VocabularyEntry
    @State private var tags: String
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(entry: VocabularyEntry, store: VocabularyStore) {
        self.store = store
        baseline = entry
        _draft = State(initialValue: entry)
        _tags = State(initialValue: entry.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "Expression", table: "Vocabulary"), text: $draft.expression)
                    TextField(String(localized: "Dictionary form", table: "Vocabulary"), text: $draft.dictionaryForm)
                    TextField(String(localized: "Meaning", table: "Vocabulary"), text: $draft.meaning, axis: .vertical)
                    TextField(String(localized: "Notes", table: "Vocabulary"), text: $draft.note, axis: .vertical)
                    TextField(String(localized: "Tags", table: "Vocabulary"), text: $tags)
                }
                ForEach($draft.examples) { $example in
                    Section(String(localized: "Example sentence", table: "Vocabulary")) {
                        TextField(String(localized: "Original text", table: "Vocabulary"), text: $example.text, axis: .vertical)
                            .onChange(of: example.text) { _, _ in
                                example.ranges = []
                                example.translation = ""
                                example.translationLanguage = nil
                                example.meaning = ""
                                example.meaningLanguage = nil
                                example.completeness = .fragment
                            }
                        TextField(String(localized: "Translation", table: "Vocabulary"), text: $example.translation, axis: .vertical)
                        TextField(String(localized: "Meaning in this context", table: "Vocabulary"),
                            text: $example.meaning, axis: .vertical)
                        Picker(String(localized: "Context type", table: "Vocabulary"), selection: $example.completeness) {
                            Text(String(localized: "Example sentence", table: "Vocabulary")).tag(VocabularyExample.Completeness.sentence)
                            Text(String(localized: "Context fragment", table: "Vocabulary")).tag(VocabularyExample.Completeness.fragment)
                        }
                        Button(String(localized: "Delete", table: "Vocabulary"), role: .destructive) {
                            let id = example.id
                            draft.examples.removeAll { $0.id == id }
                        }
                    }
                }
                Section {
                    Button {
                        draft.examples.append(VocabularyExample(id: UUID(), text: "", translation: "",
                            translationLanguage: draft.meaningLanguage, ranges: [], completeness: .fragment,
                            meaning: "", createdAt: Date()))
                    } label: { Label(String(localized: "Add example", table: "Vocabulary"), systemImage: "plus") }
                }
            }.formStyle(.grouped)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", table: "Vocabulary")) {
                    saving = true
                    var value = draft
                    value.tags = Array(Set(tags.split(whereSeparator: { $0 == "," || $0 == "，" })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                    Task {
                        if await store.update(value, basedOn: baseline) { dismiss() } else { failure = store.errorMessage }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(saving || draft.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(draft.examples.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }.padding()
        }.frame(width: 580, height: 570).interactiveDismissDisabled(saving)
    }
}
