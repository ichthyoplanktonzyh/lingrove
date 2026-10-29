import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Exercise the production graph/list shell with an isolated notebook. The existing speech
/// and dictionary sessions are injected; no real archive, model or external endpoint is used.
@MainActor
@Suite(.serialized)
struct VocabularyMeaningViewTests {
    @Test func meaningGraphAndListShareSenseDetailsAndPreserveReturnContext() async throws {
        let suite = "MeaningUI-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("meaning", forKey: "vocabularyOrganization")
        defaults.set("graph", forKey: "vocabularyBrowserMode")
        let archive = VocabularyArchive(url: nil), document = VocabularySemanticTests.fixture()
        _ = try await archive.commit(document)
        let store = VocabularyStore(archive: archive); await store.load()
        let learning = VocabularyNotebookSession(provider: LearningLexiconService(resourceURL: nil))
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech,
            learning: learning, preferences: defaults).environment(\.colorScheme, .light).background(Color.white))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        window.title = "Lingrove meaning browser acceptance"
        defer { learning.cancel(); window.close() }
        window.orderFrontRegardless()
        try await settle(host)
        let canvas = try #require(findCanvas(host))
        #expect(canvas.accessibilityChildren()?.count == 2)
        let node = document.semantics.nodes[0]
        canvas.activate(.meaning(node.id))
        try await settle(host)
        #expect(canvas.accessibilityChildren()?.count == 4)
        #expect(learning.senseID == nil)
        try screenshot(host, named: "meaning-graph")
        let sense = document.entries[0].senses[0]
        canvas.activate(.sense(.init(entryID: document.entries[0].id, senseID: sense.id)))
        try await settle(host)
        #expect(learning.senseID == sense.id)
        try screenshot(host, named: "meaning-sense-detail")
        canvas.activate(.meaning(node.id))
        try await settle(host)
        defaults.set("list", forKey: "vocabularyBrowserMode")
        try await settle(host)
        // SwiftUI retains the outgoing NSView until its spring transition completes. Wait
        // for that observable lifecycle boundary instead of assuming a 320 ms animation.
        for _ in 0..<50 {
            if findCanvas(host) == nil { break }
            try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
        }
        #expect(findCanvas(host) == nil)
        #expect(learning.senseID == nil)
        try screenshot(host, named: "meaning-list")
        let before = store.semantics
        var edited = before; edited.nodes[0].definition = "Edited without changing navigation identity."
        #expect(await store.updateSemantics(edited, basedOn: before))
        try await settle(host)
        #expect(store.entries == document.entries)
        if let seconds = Int(LingroveCompatibility.processEnvironment["LINGROVE_MEANING_UI_REVIEW_SECONDS"] ?? ""), seconds > 0 {
            try await Task.sleep(for: .seconds(min(seconds, 50)))
        }
    }

    @Test func simplifiedEditorsRenderWithoutChangingHiddenSemanticKnowledge() async throws {
        let archive = VocabularyArchive(url: nil), document = VocabularySemanticTests.fixture()
        _ = try await archive.commit(document)
        let store = VocabularyStore(archive: archive); await store.load()
        try await paint(VocabularyMeaningEditor(store: store, node: document.semantics.nodes[0]), named: "meaning-editor", height: 560)
        try await paint(VocabularyMeaningMappingEditor(store: store, mapping: document.semantics.mappings[0]), named: "grouping-editor")
        try await paint(VocabularyUsagePatternEditor(store: store, senseID: document.semantics.patterns[0].senseID,
            pattern: document.semantics.patterns[0]), named: "wording-editor")
        #expect(try await archive.load().document == document)
    }

    @Test func explanationPreferenceUpdatesGraphNamesWithoutResettingSelectionOrWritingData() async throws {
        let suite = "MultilingualUI-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("meaning", forKey: "vocabularyOrganization")
        defaults.set("graph", forKey: "vocabularyBrowserMode")
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanationLanguage = .english
        let document = VocabularyMultilingualTests.fixture(), archive = VocabularyArchive(url: nil)
        _ = try await archive.commit(document)
        let store = VocabularyStore(archive: archive); await store.load()
        let learning = VocabularyNotebookSession(provider: LearningLexiconService(resourceURL: nil))
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookRoot(settings: settings, store: store, speech: speech,
            learning: learning, preferences: defaults).environment(\.colorScheme, .light).background(Color.white))
        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: 1120, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        defer { learning.cancel(); window.close() }
        window.orderFrontRegardless(); try await settle(host)
        let canvas = try #require(findCanvas(host)), node = document.semantics.nodes[0]
        #expect(accessibilityLabels(canvas).contains("Postponement"))
        canvas.activate(.meaning(node.id)); try await settle(host)
        let entry = document.entries[2], sense = entry.senses[0]
        canvas.activate(.sense(.init(entryID: entry.id, senseID: sense.id))); try await settle(host)
        #expect(learning.senseID == sense.id)
        settings.explanationLanguage = .chinese
        for _ in 0..<50 {
            if accessibilityLabels(canvas).contains("推迟安排") { break }
            try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
        }
        #expect(accessibilityLabels(canvas).contains("推迟安排"))
        #expect(findCanvas(host) === canvas && learning.senseID == sense.id)
        #expect(accessibilityLabels(canvas).contains { $0.contains(LearningLanguage.japanese.compactLabel) })
        canvas.activate(.meaning(node.id)); try await settle(host)
        try screenshot(host, named: "multilingual-graph")
        defaults.set("list", forKey: "vocabularyBrowserMode")
        for _ in 0..<50 {
            if findCanvas(host) == nil { break }
            try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
        }
        #expect(findCanvas(host) == nil)
        try screenshot(host, named: "multilingual-list")
        #expect(try await archive.load().document == document)
    }

    private func accessibilityLabels(_ canvas: VocabularyGraphCanvasView) -> [String] {
        (canvas.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
    }

    private func paint(_ content: some View, named name: String, height: CGFloat = 420) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, .light).background(Color.white))
        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: 560, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        window.orderFrontRegardless()
        try await settle(host)
        #expect(host.fittingSize.width <= 560 && host.fittingSize.height <= height)
        try screenshot(host, named: name)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
    }
    private func findCanvas(_ view: NSView) -> VocabularyGraphCanvasView? {
        if let canvas = view as? VocabularyGraphCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas($0) }.first
    }
    private func screenshot(_ host: NSView, named name: String) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/meaning-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
}
