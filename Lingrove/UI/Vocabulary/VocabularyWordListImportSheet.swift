import SwiftUI

/// A file choice is presentation identity only. Decoded contents and the pending preview belong
/// to the sheet's session, and file access/SQLite work remain behind the existing store boundary.
struct VocabularyWordListImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let language: LearningLanguage
}

struct VocabularyWordListImportSheet: View {
    @StateObject private var session: VocabularyWordListImportSession
    let request: VocabularyWordListImportRequest
    let onImported: (VocabularyEntryImportResult) -> Void
    @Environment(\.dismiss) private var dismiss

    init(store: VocabularyStore, request: VocabularyWordListImportRequest,
         onImported: @escaping (VocabularyEntryImportResult) -> Void) {
        _session = StateObject(wrappedValue: VocabularyWordListImportSession(store: store))
        self.request = request
        self.onImported = onImported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "Import word list", table: "Vocabulary")).font(.headline)
                Spacer()
                Text(request.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(String(localized: "Preview the list before adding it. Existing entries and notes are kept.", table: "Vocabulary"))
                .font(.callout).foregroundStyle(.secondary)
            Text(String(localized: "CSV columns can be mapped below. TXT uses one expression per line.", table: "Vocabulary"))
                .font(.caption).foregroundStyle(.secondary)
            if let table = session.table {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(localized: "Language", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                        Picker(String(localized: "Language", table: "Vocabulary"), selection: $session.configuration.language) {
                            ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(localized: "Entry type", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                        Picker(String(localized: "Entry type", table: "Vocabulary"), selection: $session.configuration.kind) {
                            ForEach(VocabularyEntry.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(localized: "Meaning language", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                        VocabularyMeaningLanguagePicker(selection: $session.configuration.meaningLanguage).labelsHidden()
                    }
                }.disabled(session.saving)
                Text(String(localized: "Empty language and type cells use these defaults.", table: "Vocabulary"))
                    .font(.caption).foregroundStyle(.secondary)
                if table.format == .csv {
                    ScrollView {
                        Form {
                            Text(String(localized: "Only mapped columns are imported. Images are not included.",
                                table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                            Toggle(String(localized: "First row contains column names", table: "Vocabulary"),
                                isOn: $session.configuration.hasHeader)
                            columnPicker(.expression, table: table)
                            columnPicker(.meaning, table: table)
                            columnPicker(.example, table: table)
                            columnPicker(.exampleTranslation, table: table)
                            DisclosureGroup(String(localized: "More columns", table: "Vocabulary")) {
                                ForEach(VocabularyImportField.allCases.filter {
                                    ![.expression, .meaning, .example, .exampleTranslation].contains($0)
                                }, id: \.self) {
                                    columnPicker($0, table: table)
                                }
                            }
                        }.formStyle(.grouped)
                    }.frame(maxHeight: 280).disabled(session.saving)
                }
            }
            if session.preparing { ProgressView().frame(maxWidth: .infinity) }
            if let preview = session.preview {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 18) {
                    Text(String(localized: "New entries: \(preview.result.addedEntries)", table: "Vocabulary"))
                    Text(String(localized: "New senses: \(preview.result.addedSenses)", table: "Vocabulary"))
                    Text(String(localized: "Duplicates skipped: \(preview.result.skippedRows)", table: "Vocabulary"))
                    }
                    if showsExamples {
                        HStack(spacing: 18) {
                            Text(String(localized: "New examples: \(preview.result.addedExamples)", table: "Vocabulary"))
                            Text(String(localized: "New translations: \(preview.result.addedTranslations)", table: "Vocabulary"))
                        }
                    }
                }.font(.caption)
                previewTable(preview.inputs)
                .frame(height: CGFloat(min(showsExamples ? 4 : 8, max(2, preview.inputs.count)) + 1) * (showsExamples ? 40 : 24) + 4)
                if preview.inputs.count > 50 {
                    Text(String(localized: "Showing the first 50 rows.", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                }
                if !preview.result.hasChanges {
                    Text(String(localized: "All rows are already in the notebook.", table: "Vocabulary")).foregroundStyle(.secondary)
                }
            }
            if let failure = session.failure {
                Text(failure).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { session.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(session.saving)
                Button(String(localized: "Import", table: "Vocabulary")) {
                    Task { if let result = await session.commit() { onImported(result); dismiss() } }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(session.preparing || session.saving || session.preview?.result.hasChanges != true)
                .accessibilityIdentifier("vocabularyConfirmImport")
            }
        }
        .padding(20).frame(width: 900, height: 760)
        .interactiveDismissDisabled(session.saving)
        .task { await session.load(request.url, language: request.language) }
        .onDisappear { session.cancel() }
    }

    private struct PreviewRow: Identifiable {
        let id: Int
        let input: VocabularyEntryInput
    }

    /// Column-builder conditionals require macOS 14.4. Choose between complete tables in the
    /// ordinary ViewBuilder so the import preview still works on the app's macOS 14.0 baseline.
    @ViewBuilder private func previewTable(_ inputs: [VocabularyEntryInput]) -> some View {
        let rows = Array(inputs.prefix(50).enumerated()).map { PreviewRow(id: $0.offset, input: $0.element) }
        if showsExamples {
            Table(rows) {
                TableColumn(String(localized: "Expression", table: "Vocabulary")) { Text($0.input.expression) }
                TableColumn(String(localized: "Core meaning", table: "Vocabulary")) { Text($0.input.meaning) }
                TableColumn(String(localized: "Example sentence", table: "Vocabulary")) { Text($0.input.example).lineLimit(2) }
                TableColumn(String(localized: "Example translation", table: "Vocabulary")) {
                    Text($0.input.exampleTranslation).lineLimit(2)
                }
                TableColumn(String(localized: "Language", table: "Vocabulary")) {
                    Text($0.input.language?.label ?? String(localized: "Unspecified", table: "Learning"))
                }.width(90)
            }
        } else {
            Table(rows) {
                TableColumn(String(localized: "Expression", table: "Vocabulary")) { Text($0.input.expression) }
                TableColumn(String(localized: "Core meaning", table: "Vocabulary")) { Text($0.input.meaning) }
                TableColumn(String(localized: "Language", table: "Vocabulary")) {
                    Text($0.input.language?.label ?? String(localized: "Unspecified", table: "Learning"))
                }.width(90)
            }
        }
    }

    private var showsExamples: Bool {
        session.configuration.columns[.example] != nil || session.configuration.columns[.exampleTranslation] != nil
    }

    private func columnPicker(_ field: VocabularyImportField, table: VocabularyWordList) -> some View {
        Picker(field.label, selection: Binding(
            get: { session.configuration.columns[field] ?? -1 },
            set: { session.configuration.columns[field] = $0 >= 0 ? $0 : nil }
        )) {
            Text(String(localized: "No column", table: "Vocabulary")).tag(-1)
            ForEach(0..<table.columnCount, id: \.self) { index in
                Text(columnName(index, table: table)).tag(index)
            }
        }
    }

    private func columnName(_ index: Int, table: VocabularyWordList) -> String {
        let position = String(localized: "Column \(index + 1)", table: "Vocabulary")
        guard session.configuration.hasHeader, let cells = table.rows.first?.cells,
              index < cells.count, !cells[index].isEmpty else { return position }
        return position + " · " + String(cells[index].prefix(70))
    }
}
