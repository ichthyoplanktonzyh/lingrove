import LingroveNotebook
import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Actual notebook/create components use an isolated SQLite notebook and preferences.
@Suite(.serialized)
@MainActor
struct VocabularyEntryCreationViewTests {
    @Test func emptyNotebookAndCreationRenderWithoutMutations() async throws {
        let archive = VocabularyArchive(url: nil)
        let store = VocabularyStore(archive: archive)
        let suite = "VocabularyEntryCreationViewTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        await store.load()
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        try await paint(VocabularyNotebookView(store: store, speech: speech, preferences: defaults),
            name: "empty-notebook", size: .init(width: 1000, height: 680))
        try await paint(VocabularyEntryCreationSheet(store: store) { _ in Issue.record("Rendering must not save") },
            name: "create-entry", size: .init(width: 620, height: 590))
        #expect(store.entries.isEmpty)
        #expect(try await archive.load().document.entries.isEmpty)
    }

    private func outputFolder() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("build/vocabulary-entry-import")
    }

    private func paint<Content: View>(_ content: Content, name: String, size: CGSize) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, .light).background(Color.white))
        let window = NSPanel(contentRect: .init(origin: .init(x: -3000, y: -3000), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = outputFolder().appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        try png.write(to: output.appendingPathComponent("\(name)-\(language).png"))
        #expect(host.fittingSize.width <= size.width && host.fittingSize.height <= size.height)
    }
}
