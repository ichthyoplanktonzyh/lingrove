import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A presentation-only source editor reuses the learning Form. Import validation runs in the
/// dictionary service; this view stores only transient progress, errors and the website draft.
struct DictionarySettingsSection: View {
    @ObservedObject var settings: LearningDictionarySettings
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var website: DictionaryWebsite?

    var body: some View {
        Section(String(localized: "Dictionary sources", table: "Learning")) {
            ForEach(Array(settings.configuration.order.enumerated()), id: \.element) { index, source in
                sourceRow(source, index: index)
            }
            HStack {
                Button { importDictionary() } label: {
                    Label(String(localized: "Import MDict…", table: "Learning"), systemImage: "folder.badge.plus")
                }.disabled(importing)
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Button { website = .init(id: UUID(), name: "", template: "https://") } label: {
                    Label(String(localized: "Add lookup website…", table: "Learning"), systemImage: "plus")
                }
            }
        }.settingsItem(.dictionarySources)
        Section(String(localized: "System Dictionary", table: "Learning")) {
            Picker(String(localized: "Definition display", table: "Learning"), selection: Binding(
                get: { settings.configuration.systemFormat }, set: settings.setSystemFormat)) {
                Text(String(localized: "Formatted (experimental)", table: "Learning")).tag(SystemDictionaryFormat.formatted)
                Text(String(localized: "Plain text", table: "Learning")).tag(SystemDictionaryFormat.text)
            }
            Text(String(localized: "Formatted definitions use a private macOS interface and fall back to plain text when unavailable.",
                        table: "Learning")).font(.caption).foregroundStyle(.secondary)
        }
        Section(String(localized: "Dictionary data", table: "Learning")) {
            LabeledContent(String(localized: "Built-in expressions", table: "Learning"), value: "Wiktionary / Kaikki · CC BY-SA 4.0")
        }
        .sheet(item: $website) { draft in DictionaryWebsiteEditor(website: draft) { settings.save($0) } }
        .alert(String(localized: "Dictionary", table: "Vocabulary"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(String(localized: "Close", table: "Learning"), role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private func sourceRow(_ source: LearningDictionarySource, index: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { settings.configuration.enabled.contains(source) },
                set: { settings.setEnabled($0, for: source) })) {
                    SettingsRowLabel(title: settings.configuration.name(for: source),
                                     description: description(source), systemImage: "books.vertical")
                }.disabled(settings.configuration.enabled == [source])
            if let site = settings.configuration.websites.first(where: { $0.source == source }) {
                Button { website = site } label: { Image(systemName: "pencil") }
                    .help(String(localized: "Edit website", table: "Learning"))
                    .accessibilityLabel(String(localized: "Edit website", table: "Learning"))
            }
            if let library = settings.configuration.libraries.first(where: { $0.source == source }) {
                Button { attachResources(library) } label: { Image(systemName: "paperclip") }
                    .disabled(importing).help(String(localized: "Resource files…", table: "Learning"))
                    .accessibilityLabel(String(localized: "Resource files…", table: "Learning"))
            }
            if source.kind == .mdict || source.kind == .website {
                Button { settings.remove(source) } label: { Image(systemName: "minus.circle") }
                    .help(String(localized: "Remove source", table: "Learning"))
                    .accessibilityLabel(String(localized: "Remove source", table: "Learning"))
            }
            HStack(spacing: 4) {
                Button { settings.move(source, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).help(String(localized: "Move source up", table: "Learning"))
                    .accessibilityLabel(String(localized: "Move source up", table: "Learning"))
                Button { settings.move(source, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == settings.configuration.order.count - 1)
                    .help(String(localized: "Move source down", table: "Learning"))
                    .accessibilityLabel(String(localized: "Move source down", table: "Learning"))
            }.buttonStyle(.borderless)
        }
    }

    private func description(_ source: LearningDictionarySource) -> String {
        switch source.kind {
        case .bundled: String(localized: "Phrases and fixed expressions", table: "Learning")
        case .system: String(localized: "Enabled macOS dictionaries", table: "Learning")
        case .online: String(localized: "dictionaryapi.dev · Sends only the lookup term when enabled", table: "Learning")
        case .website: String(localized: "Opens in your browser when clicked", table: "Learning")
        case .mdict: settings.configuration.libraries.first { $0.source == source }.map {
            URL(fileURLWithPath: $0.mdx.path).lastPathComponent + " · " + String($0.entryCount)
        } ?? "MDict"
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mdx") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                guard settings.add(try await MDictLibraryService.importedFile(url)) else {
                    throw DictionaryServiceFailure.tooLarge
                }
            } catch let failure as DictionaryServiceFailure {
                errorMessage = failure.localizedDescription
            } catch { errorMessage = DictionaryServiceFailure.invalidFile.localizedDescription }
        }
    }

    private func attachResources(_ library: MDictLibraryDescriptor) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mdd") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                guard settings.add(try await MDictLibraryService.attaching(urls, to: library)) else {
                    throw DictionaryServiceFailure.tooLarge
                }
            } catch let failure as DictionaryServiceFailure {
                errorMessage = failure.localizedDescription
            } catch { errorMessage = DictionaryServiceFailure.invalidFile.localizedDescription }
        }
    }
}
