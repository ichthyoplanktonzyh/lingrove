import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Native hosted views verify the additive column against the existing notebook, with private
/// preferences and fixture data. Screenshots retain the actual SwiftUI layout for visual review.
@MainActor
@Suite(.serialized)
struct VocabularyClassificationViewTests {
    @Test func categorySelectionFiltersMeaningsAndKeepsExistingBrowserControls() async throws {
        let suite = "CategoryUI-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("meaning", forKey: "vocabularyOrganization")
        defaults.set("list", forKey: "vocabularyBrowserMode")
        var document = VocabularySemanticTests.fixture()
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: document.semantics.nodes)
        let category = try #require(document.classification.categories.first { $0.key == "content.time.timing" })
        document.classification.memberships = [.init(id: UUID(), nodeID: document.semantics.nodes[0].id, categoryID: category.id)]
        let archive = VocabularyArchive(url: nil); _ = try await archive.commit(document)
        let store = VocabularyStore(archive: archive); await store.load()
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech, preferences: defaults)
            .environment(\.vocabularyMeaningLanguages, [.chinese]).environment(\.colorScheme, .light))
        let window = makeWindow(host, width: 1260, height: 760)
        defer { window.close() }
        try await settle(host)
        let tables = tableViews(host).sorted { host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX }
        #expect(tables.count == 2)
        let categories = try #require(tables.first), meanings = try #require(tables.last)
        let before = meanings.numberOfRows
        // Two virtual rows, the content section header, then the authored root order. Time is
        // root four; native table selection exercises the production binding and filter path.
        categories.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        try await settle(host)
        #expect(meanings.numberOfRows == 1 && before > meanings.numberOfRows)
        #expect(defaults.string(forKey: "vocabularyOrganization") == "meaning")
        #expect(defaults.string(forKey: "vocabularyBrowserMode") == "list")
        try screenshot(host, named: "category-time-filter")
        if let seconds = Int(LingroveCompatibility.processEnvironment["LINGROVE_CLASSIFICATION_UI_REVIEW_SECONDS"] ?? ""), seconds > 0 {
            try await Task.sleep(for: .seconds(min(seconds, 50)))
        }
        categories.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await settle(host)
        #expect(meanings.numberOfRows == before)
        #expect(try await archive.load().document == document)
        defaults.set("entry", forKey: "vocabularyOrganization")
        try await settle(host)
        #expect(tableViews(host).count == 1)
        try screenshot(host, named: "entry-browser-unchanged")
    }

    @Test func categoryEditorsRenderAtNativeSheetSizeInBothAppearances() async throws {
        let archive = VocabularyArchive(url: nil)
        var document = VocabularySemanticTests.fixture()
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: document.semantics.nodes)
        _ = try await archive.commit(document)
        let store = VocabularyStore(archive: archive); await store.load()
        try await paint(VocabularyCategoryEditor(store: store, preferredLanguages: [.chinese]), named: "new-category", dark: false)
        try await paint(VocabularyMeaningCategorySheet(store: store, nodeID: document.semantics.nodes[0].id),
            named: "meaning-categories", dark: true)
    }

    private func paint(_ content: some View, named name: String, dark: Bool) async throws {
        let host = NSHostingView(rootView: content.environment(\.vocabularyMeaningLanguages, [.chinese])
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = makeWindow(host, width: 560, height: 420)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        try await settle(host)
        #expect(host.fittingSize.width <= 560 && host.fittingSize.height <= 420)
        try screenshot(host, named: name)
    }
    private func makeWindow(_ host: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: width, height: height),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
        return window
    }
    private func settle(_ host: NSView) async throws {
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
    }
    private func tableViews(_ view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tableViews($0) }
    }
    private func screenshot(_ host: NSView, named name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/validation/classification/screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
