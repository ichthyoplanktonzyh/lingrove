import AppKit
import LingroveNotebook
import SwiftUI
import Testing
@testable import Lingrove

/// Production SwiftUI is rendered against an isolated library. Search does not borrow the
/// user's model directory, start downloads, or require a native inference model for this check.
@Suite(.serialized)
@MainActor
struct VocabularySearchViewTests {
    @Test func browsingKeepsSetupOutOfContentAndResultsNavigateBySense() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        for entry in fixture.entries {
            await store.save(.init(expression: entry.expression, dictionaryForm: entry.dictionaryForm, language: .english,
                kind: .expression, meaning: try #require(entry.senses.first?.meaning)))
        }
        let node = try #require(fixture.semantics.nodes.first)
        let mappings = store.entries.flatMap { $0.senses.map { VocabularyMeaningMapping(nodeID: node.id, senseID: $0.id) } }
        let saved = await store.updateSemantics(.init(nodes: [node], mappings: mappings), basedOn: store.semantics)
        try #require(saved)
        let search = VocabularySearchController(store: store, directoryURL: folder, cacheURL: nil)
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech, search: search, preferences: defaults))
        host.frame = .init(x: 0, y: 0, width: 1040, height: 720)
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1040, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.title = "Lingrove Search UI Fixture"
        window.makeKeyAndOrderFront(nil)
        defer { search.suspend(); window.close() }
        try await paint(host, filename: "browsing")
        // Optional local inspection keeps the isolated production view available to native UI
        // tools. CI never waits, and no interaction with the user's own notebook is necessary.
        if let value = LingroveCompatibility.processEnvironment["LINGROVE_SEARCH_UI_HOLD"],
           let seconds = Int(value), seconds > 0, seconds <= 60 {
            try await Task.sleep(for: .seconds(seconds))
        }
        #expect(!search.downloads.state(for: VocabularySearchCatalog.model).isDownloading)
        var selected: (senseID: UUID, nodeID: UUID?)?
        let results = NSHostingView(rootView: VocabularySearchResultsView(controller: search, query: "产生影响", language: .english,
            tag: "", selectedSenseID: nil, onSelect: { selected = ($0, $1) }, senseMenu: { _ in EmptyView() }))
        window.contentView = results
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(30))
            if !search.results.isEmpty { break }
        }
        try await paint(results, filename: "results")
        #expect(search.results.count == 5)
        let group = try #require(search.results.groups.first)
        let table = try #require(findTable(results))
        // Native sidebar sections insert a nonselectable header before the first expression.
        let rows = (0..<table.numberOfRows).filter {
            table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle != true &&
                table.delegate?.tableView?(table, shouldSelectRow: $0) != false
        }
        #expect(rows.count == group.documents.count)
        let row = try #require(rows.first)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(selected?.senseID == group.documents.first?.id)
        #expect(selected?.nodeID == node.id)
        #expect(SettingsSearchRanker.rank("embedding", in: SettingsItem.allCases).contains(.vocabularySearch))
        let navigation = SettingsNavigationModel()
        navigation.reveal(.vocabularySearch)
        #expect(navigation.engineTask == .vocabularySearch)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    private func paint(_ view: NSView, filename: String) async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); view.layoutSubtreeIfNeeded() }
        guard LingroveCompatibility.processEnvironment["LINGROVE_SEARCH_UI_CAPTURE"] == "1" else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/search-ui")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent(filename + ".png"))
    }

    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(findTable).first
    }
}
