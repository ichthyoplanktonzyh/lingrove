import AppKit
import SwiftUI
import Testing
@testable import Cotabby

/// Exercises real production SwiftUI roots without opening real archives or starting a voice.
@Suite(.serialized)
@MainActor
struct VocabularyNotebookViewTests {
    @Test func libraryAndEditorRenderWithoutReadingRealUserData() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let text = "Please keep me posted on the progress."
        let capture = VocabularyCapture(expression: "keep me posted", dictionaryForm: "keep someone posted", language: .english,
            kind: .expression, meaning: "随时告诉我最新进展", example: VocabularyPolicy.example(text: text,
                ranges: [(text as NSString).range(of: "keep me posted")], language: .english))
        await store.save(capture)
        let entry = try #require(store.entries.first)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech, selectedID: entry.id))
        window.contentView = view
        window.orderFrontRegardless()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)); view.layoutSubtreeIfNeeded() }
        #expect(view.fittingSize.width >= 760)
        #expect(!speech.isPlaying(SpeechTarget(ownerID: entry.id, itemID: "vocabulary.expression")))
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] ??
            FileManager.default.temporaryDirectory.appendingPathComponent("LingroveVocabularyTests").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("library-\(name).png"))
            }
        }
        window.contentView = NSHostingView(rootView: VocabularyEntryEditor(entry: entry, store: store))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentView?.fittingSize.width == 580)
    }
}
