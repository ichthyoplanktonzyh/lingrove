import AppKit
import SwiftUI
import Testing
@testable import Cotabby

/// Opt-in acceptance hosts the actual notebook with a private fixture. A UI driver must export
/// three files through native save panels before signaling completion; no real notebook is read.
extension VocabularyExportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COTABBY_UI_EXPORT_ACCEPTANCE"] == "1"))
    func nativeExportSavesTextCSVAndImageZIP() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["COTABBY_UI_EXPORT_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let archive = VocabularyArchive(url: nil), (entries, image) = try fixture()
        _ = try await archive.commitWithImages(.init(entries: entries), supplied: [image.reference.filename: image.data])
        let store = VocabularyStore(archive: archive); await store.load()
        let suite = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech, selectedID: entries[0].id))
        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Lingrove export acceptance"; window.isReleasedWhenClosed = false
        window.contentView = host; window.level = .floating; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = output.appendingPathComponent("done")
        for _ in 0..<1_200 {
            if FileManager.default.fileExists(atPath: done.path) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(FileManager.default.fileExists(atPath: done.path))
        let text = try String(contentsOf: output.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(text.contains("bank") && text.contains("银行") && text.contains("金融机构"))
        let csv = try String(contentsOf: output.appendingPathComponent("table.csv"), encoding: .utf8)
        #expect(csv.contains("dictionary_form") && csv.contains("contextual_meaning"))
        let zip = try Data(contentsOf: output.appendingPathComponent("portable.zip"))
        #expect(zip.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        #expect(store.entries.count == 2 && store.entries[0].senses.count == 2)
    }
}
