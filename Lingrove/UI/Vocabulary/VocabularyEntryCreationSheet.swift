import SwiftUI

/// This sheet owns an unsaved value, not a placeholder archive entry. Cancel has no side effect;
/// Save waits for the shared store's atomic addition and returns the exact sense to reveal.
struct VocabularyEntryCreationSheet: View {
    @ObservedObject var store: VocabularyStore
    let onSaved: (VocabularyEntryImportResult) -> Void
    @State private var input: VocabularyEntryInput
    @State private var tags = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var expressionFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, language: LearningLanguage = .english,
         onSaved: @escaping (VocabularyEntryImportResult) -> Void) {
        self.store = store
        self.onSaved = onSaved
        _input = State(initialValue: .init(language: language))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(String(localized: "Add entry", table: "Vocabulary")).font(.headline).padding(18)
            Divider()
            Form {
                Section {
                    TextField(String(localized: "Expression", table: "Vocabulary"), text: $input.expression)
                        .focused($expressionFocused).accessibilityIdentifier("vocabularyNewExpression")
                    Picker(String(localized: "Language", table: "Vocabulary"), selection: $input.language) {
                        ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    Picker(String(localized: "Entry type", table: "Vocabulary"), selection: $input.kind) {
                        ForEach(VocabularyEntry.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField(String(localized: "Dictionary form", table: "Vocabulary"), text: $input.dictionaryForm)
                }
                Section {
                    TextField(String(localized: "Core meaning", table: "Vocabulary"), text: $input.meaning, axis: .vertical)
                        .accessibilityIdentifier("vocabularyNewMeaning")
                    VocabularyMeaningLanguagePicker(selection: $input.meaningLanguage)
                    TextField(String(localized: "Notes", table: "Vocabulary"), text: $input.note, axis: .vertical)
                    TextField(String(localized: "Tags", table: "Vocabulary"), text: $tags)
                    Text(String(localized: "Separate tags with commas or semicolons.", table: "Vocabulary"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text(String(localized: "Existing entries keep their content. New content is added as a separate sense.",
                        table: "Vocabulary"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).disabled(saving)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).padding(12) }
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button(String(localized: "Save", table: "Vocabulary"), action: save)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(saving || VocabularyPolicy.normalized(input.expression).isEmpty)
                    .accessibilityIdentifier("vocabularyCreateEntry")
            }.padding(16)
        }
        .frame(width: 620, height: 590)
        .interactiveDismissDisabled(saving)
        .onAppear { expressionFocused = true }
    }

    private func save() {
        var value = input
        value.tags = tags.components(separatedBy: CharacterSet(charactersIn: ",，;；"))
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                let result = try await store.addEntries([value])
                onSaved(result); dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Shared optional annotation-language control. “Not specified” avoids inventing provenance for
/// a manually entered meaning; imported language columns can provide a more precise row value.
struct VocabularyMeaningLanguagePicker: View {
    @Binding var selection: LearningLanguage?

    var body: some View {
        Picker(String(localized: "Meaning language", table: "Vocabulary"), selection: $selection) {
            Text(String(localized: "Not specified", table: "Vocabulary")).tag(Optional<LearningLanguage>.none)
            ForEach(LearningLanguage.allCases) { Text($0.label).tag(Optional($0)) }
        }
    }
}
