import SwiftUI

/// Website and imported-book drafts share these two native pickers. Neither editor guesses
/// a language from a filename, encoding or the spelling of a short query.
struct DictionaryLanguageFields: View {
    @Binding var entry: LearningLanguage?
    @Binding var definition: LearningLanguage?
    @Binding var multilingual: Bool
    private enum EntryChoice: Hashable { case unspecified, multilingual, language(LearningLanguage) }

    var body: some View {
        Picker(String(localized: "Entry language", table: "Learning"), selection: Binding(
            get: { entry.map(EntryChoice.language) ?? (multilingual ? .multilingual : .unspecified) },
            set: { choice in
                if case .language(let language) = choice { entry = language } else { entry = nil }
                multilingual = choice == .multilingual
            })) {
                Text(String(localized: "Unspecified", table: "Learning")).tag(EntryChoice.unspecified)
                Text(String(localized: "Multilingual", table: "Learning")).tag(EntryChoice.multilingual)
                ForEach(LearningLanguage.allCases) { Text($0.label).tag(EntryChoice.language($0)) }
            }
        Picker(String(localized: "Definition language", table: "Learning"), selection: $definition) { choices }
    }

    private var choices: some View {
        Group {
            Text(String(localized: "Unspecified", table: "Learning")).tag(nil as LearningLanguage?)
            ForEach(LearningLanguage.allCases) { Text($0.label).tag(Optional($0)) }
        }
    }
}

/// Editing a book's language annotation never reparses or rewrites the user's MDX/MDD files.
struct DictionaryBookLanguageEditor: View {
    let library: MDictLibraryDescriptor
    let save: (DictionaryLanguagePair) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var entry: LearningLanguage?
    @State private var definition: LearningLanguage?
    @State private var multilingual = false
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(library.name).font(.headline)
            Form { DictionaryLanguageFields(entry: $entry, definition: $definition, multilingual: $multilingual) }
            HStack {
                Button(String(localized: "Cancel", table: "Learning")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Save", table: "Learning")) {
                    if save(.init(entry: entry, definition: definition, multilingual: multilingual)) { dismiss() } else {
                        saveFailed = true
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
            .onAppear {
                entry = library.languages?.entry; definition = library.languages?.definition
                multilingual = library.languages?.multilingual == true
            }
            .alert(DictionaryServiceFailure.tooLarge.localizedDescription, isPresented: $saveFailed) {
                Button(String(localized: "Close", table: "Learning"), role: .cancel) {}
            }
    }
}
