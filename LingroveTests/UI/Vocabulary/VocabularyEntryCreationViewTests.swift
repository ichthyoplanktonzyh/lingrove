import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Actual notebook/create/import components use an isolated SQLite notebook and preferences.
/// Optional native acceptance lets a UI driver exercise Save, Cancel and the file picker.
@Suite(.serialized)
@MainActor
struct VocabularyEntryCreationViewTests {
    @Test func emptyNotebookCreationAndImportPreviewRenderWithoutMutations() async throws {
        let archive = VocabularyArchive(url: nil)
        let store = VocabularyStore(archive: archive)
        let suite = "VocabularyEntryCreationViewTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let csv = folder.appendingPathComponent("sample.csv")
        try Data(("expression,meaning,example,translation\n" +
            "serendipity,a happy discovery,It was pure serendipity.,这纯属机缘巧合。\n" +
            "bank,river edge,We sat by the bank.,我们坐在河岸边。\n" +
            "bank,river edge,The bank is steep.,河岸很陡。").utf8).write(to: csv)
        await store.load()
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        try await paint(VocabularyNotebookView(store: store, speech: speech, preferences: defaults),
            name: "empty-notebook", size: .init(width: 1000, height: 680))
        try await paint(VocabularyEntryCreationSheet(store: store) { _ in Issue.record("Rendering must not save") },
            name: "create-entry", size: .init(width: 620, height: 590))
        try await paint(VocabularyWordListImportSheet(store: store,
            request: .init(url: csv, language: .english)) { _ in Issue.record("Preview must not import") },
            name: "import-preview", size: .init(width: 900, height: 760))
        #expect(store.entries.isEmpty)
        #expect(try await archive.load().document.entries.isEmpty)
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_UI_WORD_LIST_ACCEPTANCE"] == "1"))
    func nativeCreateCancelAndImportUseAnIsolatedNotebook() async throws {
        let output = outputFolder().appendingPathComponent("acceptance")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let done = output.appendingPathComponent("done")
        try? FileManager.default.removeItem(at: done)
        let source = output.appendingPathComponent("words.csv")
        try Data("expression,meaning\nserendipity,a happy discovery\nbank,river edge\nbank,financial institution".utf8).write(to: source)
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.load()
        let suite = "VocabularyEntryCreationAcceptance." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let learning = VocabularyNotebookSession(provider: LearningLexiconService(resourceURL: nil))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Lingrove word list acceptance"
        window.contentView = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech,
            learning: learning, preferences: defaults))
        window.level = .floating; window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        for _ in 0..<480 {
            if FileManager.default.fileExists(atPath: done.path) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(FileManager.default.fileExists(atPath: done.path))
        let word = try #require(store.entries.first { $0.expression == "serendipity" })
        let bank = try #require(store.entries.first { $0.expression == "bank" })
        #expect(store.entries.count == 2 && word.senses.count == 1 && bank.senses.count == 2)
        #expect(word.senses[0].meaning == "a happy discovery")
        #expect(Set(bank.senses.map(\.meaning)) == ["river edge", "financial institution"])
        #expect(store.entries.allSatisfy { $0.senses.allSatisfy(\.supportsGeneralExplanation) })
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
