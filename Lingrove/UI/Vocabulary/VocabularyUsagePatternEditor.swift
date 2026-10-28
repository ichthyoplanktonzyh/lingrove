import SwiftUI

/// This sheet edits practical wording and usage notes. Structured slot identities and their
/// bindings are maintained by semantic tools; ordinary edits keep them and their source intact.
struct VocabularyUsagePatternEditor: View {
    @ObservedObject var store: VocabularyStore
    private let baseline: VocabularySemanticIndex
    @State private var pattern: VocabularyUsagePattern
    @State private var collocations: String
    @State private var showingDetails = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, senseID: UUID, pattern: VocabularyUsagePattern? = nil) {
        self.store = store; baseline = store.semantics
        let value = pattern ?? .init(senseID: senseID, template: "")
        _pattern = State(initialValue: value)
        _collocations = State(initialValue: value.collocations.joined(separator: "\n"))
    }

    var body: some View {
        VocabularySemanticEditorFrame(title: String(localized: "Edit usage pattern", table: "Vocabulary"), saving: saving,
            canSave: !pattern.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, failure: failure, save: save) {
            Section {
                if pattern.slots.isEmpty {
                    TextField(String(localized: "Usage pattern", table: "Vocabulary"), text: $pattern.template, axis: .vertical)
                } else {
                    LabeledContent(String(localized: "Usage pattern", table: "Vocabulary")) {
                        VocabularyPatternTemplateText(template: pattern.template)
                    }
                }
                TextField(String(localized: "Usage note", table: "Vocabulary"), text: $pattern.note, axis: .vertical)
            }
            DisclosureGroup(String(localized: "Details", table: "Learning"), isExpanded: $showingDetails) {
                Picker(String(localized: "Formality", table: "Vocabulary"), selection: $pattern.formality) {
                    ForEach(VocabularyUsagePattern.Formality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(String(localized: "Medium", table: "Vocabulary"), selection: $pattern.medium) {
                    ForEach(VocabularyUsagePattern.Medium.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField(String(localized: "Region or dialect", table: "Vocabulary"), text: $pattern.region)
                TextField(String(localized: "Collocations", table: "Vocabulary"), text: $collocations, axis: .vertical)
            }
        }
    }

    private func save() {
        var value = pattern
        value.collocations = collocations.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var edited = baseline
        if let index = edited.patterns.firstIndex(where: { $0.id == value.id }) {
            edited.patterns[index] = value
        } else { edited.patterns.append(value) }
        saving = true
        Task {
            if await store.updateSemantics(edited, basedOn: baseline) { dismiss() } else { failure = store.errorMessage }
            saving = false
        }
    }
}
