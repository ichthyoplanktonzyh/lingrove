import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A native grouped form edits one export session. It owns the save panel/task lifecycle only;
/// the store prepares an immutable preview and writes those same bytes away from MainActor.
struct VocabularyExportSheet: View {
    @StateObject private var session: VocabularyExportSession
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?
    @State private var panel: NSSavePanel?
    @State private var choosingDestination = false

    init(store: VocabularyStore, request: VocabularyExportRequest) {
        _session = StateObject(wrappedValue: VocabularyExportSession(store: store, request: request))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Export scope", table: "Vocabulary")) {
                    Picker(String(localized: "Range", table: "Vocabulary"), selection: $session.scope) {
                        ForEach(VocabularyExportScope.allCases) { scope in
                            Text(scope.label).tag(scope).disabled(session.request.selections(scope).isEmpty)
                        }
                    }
                    if let package = session.package {
                        HStack {
                            count(String(localized: "Expressions", table: "Vocabulary"), package.entryCount)
                            Spacer(); count(String(localized: "Senses", table: "Vocabulary"), package.senseCount)
                            Spacer(); count(String(localized: "Usages", table: "Vocabulary"), package.exampleCount)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(String(localized: "Export format", table: "Vocabulary")) {
                    Picker(String(localized: "Format", table: "Vocabulary"), selection: $session.configuration.format) {
                        ForEach(VocabularyExportFormat.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    if session.configuration.format == .text {
                        Picker(String(localized: "Text layout", table: "Vocabulary"), selection: $session.configuration.textStyle) {
                            ForEach(VocabularyExportTextStyle.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    if session.configuration.format == .csv {
                        Toggle(String(localized: "Spreadsheet compatibility", table: "Vocabulary"),
                            isOn: $session.configuration.spreadsheetCompatibility)
                            .help(String(localized: "Adds a UTF-8 signature and protects cells that start with formula symbols.",
                                table: "Vocabulary"))
                    }
                }
                if !session.configuration.isExpressionList { contentOptions }
                Section(String(localized: "Preview", table: "Vocabulary")) {
                    if session.loading { ProgressView().controlSize(.small) }
                    if let package = session.package {
                        ScrollView(.horizontal) {
                            Text(package.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .lineLimit(12).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 220)
                    }
                    if let message = session.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                }
            }.formStyle(.grouped).disabled(session.saving || choosingDestination || operation != nil)
            HStack {
                if session.saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { operation?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(choosingDestination)
                Button(String(localized: "Export…", table: "Vocabulary"), action: chooseDestination)
                    .keyboardShortcut(.defaultAction).disabled(!session.canExport || choosingDestination || operation != nil)
            }.padding()
        }
        .frame(width: 700, height: 710).interactiveDismissDisabled(choosingDestination)
        .task(id: session.key) { await session.prepare() }
        .onDisappear { operation?.cancel(); session.cancel(); panel?.cancel(nil) }
    }

    private var contentOptions: some View {
        Section(String(localized: "Export content", table: "Vocabulary")) {
            Toggle(String(localized: "Meanings", table: "Vocabulary"), isOn: $session.configuration.meanings)
            Toggle(String(localized: "Examples and translations", table: "Vocabulary"), isOn: $session.configuration.examples)
            Toggle(String(localized: "Notes and tags", table: "Vocabulary"), isOn: $session.configuration.notes)
            Toggle(String(localized: "AI explanation", table: "Learning"), isOn: $session.configuration.explanation)
            Toggle(String(localized: "Supplemental content", table: "Vocabulary"), isOn: $session.configuration.content)
            Toggle(String(localized: "Attach images (ZIP)", table: "Vocabulary"), isOn: $session.configuration.images)
                .disabled(!session.configuration.content)
        }
    }
    private func count(_ label: String, _ value: Int) -> some View { Text(label + ": " + value.formatted()) }

    private func chooseDestination() {
        guard session.canExport, let package = session.package else { return }
        let panel = NSSavePanel(); self.panel = panel
        let dataType: UTType = switch package.configuration.format {
        case .text: .plainText
        case .csv: .commaSeparatedText
        case .json: .json
        }
        panel.allowedContentTypes = [package.configuration.includesImages ? .zip : dataType]
        panel.nameFieldStringValue = package.filename
        choosingDestination = true
        panel.begin { response in
            choosingDestination = false; self.panel = nil
            guard session.isActive, response == .OK, let url = panel.url else { return }
            operation = Task {
                defer { operation = nil }
                if await session.save(package, to: url) { dismiss() }
            }
        }
    }
}
