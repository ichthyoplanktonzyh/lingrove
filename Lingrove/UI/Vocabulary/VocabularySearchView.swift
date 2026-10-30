import SwiftUI

/// The native search suggestions borrow the app-owned downloader. Installation is a secondary
/// search action, so neither browsing nor focusing the search field starts a network request.
/// Closing suggestions leaves transfers with the controller; reopening restores their progress.
struct VocabularySearchSuggestionsView: View {
    @ObservedObject var controller: VocabularySearchController
    private var state: ModelDownloadState { controller.downloads.state(for: VocabularySearchCatalog.model) }
    private var actionTitle: String {
        if case .failed = state { return String(localized: "Retry") }
        return String(localized: "Enable semantic search", table: "Vocabulary")
    }
    private var showsSuggestion: Bool {
        guard state == .downloaded else { return true }
        switch controller.status {
        case .indexing, .failed: return true
        case .notInstalled, .ready: return false
        }
    }

    var body: some View {
        if showsSuggestion {
            VStack(alignment: .leading, spacing: 6) {
                switch state {
                case .idle, .failed:
                    Button(action: controller.download) {
                        // macOS converts search suggestions into native menu items, extracting
                        // the label title rather than preserving an arbitrary HStack's trailing
                        // views. Keep the size in that title so it cannot silently disappear.
                        Label(actionTitle + " · 639 MB", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vocabularySearchDownload")
                    .help(String(localized: "Download the local search model (639 MB) to search across languages offline.",
                        table: "Vocabulary"))
                    if case .failed(let message) = state {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).help(message)
                    }
                case .downloading, .paused:
                    // Native menu text and actions remain visible in search suggestions; custom
                    // progress bars and nested icon buttons belong to the full Settings surface.
                    Text(state.statusText).disabled(true)
                    if state.isPaused {
                        Button(String(localized: "Resume download"), action: controller.download)
                    } else {
                        Button(String(localized: "Pause download")) {
                            controller.downloads.pause(VocabularySearchCatalog.model)
                        }
                    }
                    Button(String(localized: "Cancel download")) {
                        controller.downloads.cancel(VocabularySearchCatalog.model)
                    }
                case .downloaded:
                    installedStatus
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var installedStatus: some View {
        switch controller.status {
        case let .indexing(completed, total):
            Text(String(localized: "Preparing expression search…", table: "Vocabulary") + " · \(completed)/\(total)")
                .disabled(true)
        case .failed(let message):
            Button(String(localized: "Manage models", table: "Learning")) { controller.openModelSettings?() }
                .buttonStyle(.plain)
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).help(message)
        case .notInstalled, .ready:
            EmptyView()
        }
    }
}

/// Settings retains the full resource explanation and deletion controls. The notebook uses the
/// compact suggestions above; both surfaces observe the same app-owned transfer and index state.
struct VocabularySearchModelView: View {
    @ObservedObject var controller: VocabularySearchController

    private var state: ModelDownloadState { controller.downloads.state(for: VocabularySearchCatalog.model) }
    private var downloadTitle: String {
        if case .failed = state { return String(localized: "Retry") }
        return String(localized: "Download and enable", table: "Vocabulary")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Find expressions in your own words", table: "Vocabulary")).font(.headline)
                    Text(String(localized: "Download the local search model (639 MB) to search across languages offline.",
                        table: "Vocabulary"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(VocabularySearchCatalog.model.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actions
            }
            if state.isDownloading || state.isPaused { ModelDownloadProgressBar(state: state) }
            statusText
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
        .accessibilityIdentifier("vocabularySearchModel")
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .idle, .failed:
            Button(downloadTitle, action: controller.download)
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("vocabularySearchDownload")
        case .downloading, .paused:
            ModelDownloadTransferControls(state: state, onResume: controller.download,
                onPause: { controller.downloads.pause(VocabularySearchCatalog.model) },
                onCancel: { controller.downloads.cancel(VocabularySearchCatalog.model) })
        case .downloaded:
            Button(String(localized: "Delete"), role: .destructive) { Task { await controller.removeModel() } }
                .controlSize(.small)
        }
    }

    @ViewBuilder private var statusText: some View {
        if case .failed(let message) = state {
            Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        } else if case .failed(let message) = controller.status {
            Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        } else if case let .indexing(completed, total) = controller.status {
            ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                Text(String(localized: "Preparing expression search…", table: "Vocabulary")).font(.caption)
            }
        } else if state == .downloaded {
            Text(String(localized: "Installed")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The notebook header counts displayed hits while searching. This tiny observed child follows
/// the app-owned controller's asynchronous updates; legacy category/literal counts describe a
/// different collection and can disagree with the actual result list.
struct VocabularySearchCountView: View {
    @ObservedObject var controller: VocabularySearchController

    var body: some View { Text("\(controller.results.count)") }
}

/// A flat relevance-ordered sense list serves both notebook organizations and graph searches.
/// Selecting a hit reuses the existing detail view with stable IDs; no generated text is inserted.
struct VocabularySearchResultsView: View {
    @ObservedObject var controller: VocabularySearchController
    let query: String
    let language: LearningLanguage?
    let tag: String
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(controller.results) { hit in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(hit.document.expression).font(.headline)
                        Spacer()
                        if let language = hit.document.language {
                            Text(language.compactLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(hit.document.meaning).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                .padding(.vertical, 5).tag(hit.id)
                .accessibilityIdentifier("vocabularySearchHit." + hit.id.uuidString)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if controller.results.isEmpty {
                if controller.isSearching { ProgressView() } else {
                    ContentUnavailableView(String(localized: "No matching expressions", table: "Vocabulary"),
                        systemImage: "text.magnifyingglass")
                }
            }
        }
        .onAppear(perform: updateQuery)
        .onChange(of: query) { _, _ in updateQuery() }
        .onChange(of: language) { _, _ in updateQuery() }
        .onChange(of: tag) { _, _ in updateQuery() }
        .accessibilityIdentifier("vocabularySearchResults")
    }

    private func updateQuery() { controller.search(query, language: language, tag: tag) }
}
