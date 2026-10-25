import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Opt-in native acceptance exposes only a private notebook and a known CSV. A UI driver chooses
/// the file, confirms the preview, inspects the saved examples, then signals completion on disk.
@Suite(.serialized)
@MainActor
struct VocabularyExampleImportAcceptanceTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_UI_EXAMPLE_IMPORT_ACCEPTANCE"] == "1"))
    func nativeCSVImportKeepsSentencesAndTranslations() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let output = root.appendingPathComponent("build/vocabulary-import-examples/acceptance")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let done = output.appendingPathComponent("done")
        try? FileManager.default.removeItem(at: done)
        let csv = root.appendingPathComponent("docs/vocabulary-import-example.csv")
        try Data(contentsOf: csv).write(to: output.appendingPathComponent("examples.csv"))
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.load()
        let suite = "VocabularyExampleImportAcceptance." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let learning = VocabularyNotebookSession(provider: LearningLexiconService(resourceURL: nil))
        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: 1100, height: 850),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Lingrove example import acceptance"
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech,
            learning: learning, preferences: defaults))
        window.contentView = host; window.level = .floating; window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        for _ in 0..<1_200 {
            if FileManager.default.fileExists(atPath: done.path) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(FileManager.default.fileExists(atPath: done.path))
        let bank = try #require(store.entries.first { $0.expression == "bank" })
        #expect(store.entries.count == 2 && bank.senses.count == 1 && bank.examples.count == 2)
        #expect(bank.examples.map(\.text) == ["We sat by the bank.", "The bank is steep."])
        #expect(bank.examples.map(\.translation) == ["我们坐在河岸边。", "河岸很陡。"])
        #expect(bank.examples.allSatisfy { !$0.ranges.isEmpty })
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("saved-examples.png"))
    }
}
