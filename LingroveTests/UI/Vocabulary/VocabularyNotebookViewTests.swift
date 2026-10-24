import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Exercises real production SwiftUI roots without opening real archives or starting a voice.
@Suite(.serialized)
@MainActor
struct VocabularyNotebookViewTests {
    @Test func ordinaryLibraryCommandInstallsAndRetainsTheHostedRoot() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let controller = VocabularyWindowController(store: store, speech: speech,
            dictionaryProvider: LearningLexiconService(resourceURL: nil),
            dictionarySettings: LearningDictionarySettings(defaults: defaults), preferences: defaults)
        controller.show()
        defer { controller.close() }
        let host = try #require(controller.window?.contentView as? NSHostingView<VocabularyNotebookView>)
        controller.show()
        #expect(controller.window?.contentView === host)
    }

    @Test func savingAnExplanationKeepsTheBrowsedEntrySelected() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        for text in ["The bank opens early.", "We walked along the bank."] {
            await store.save(VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english,
                kind: .word, example: VocabularyPolicy.example(text: text,
                    ranges: [(text as NSString).range(of: "bank")], language: .english)))
        }
        let initial = try #require(store.entries.first)
        let learning = VocabularyNotebookSession(provider: LearningLexiconService(resourceURL: nil))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech,
            selectedID: initial.id, learning: learning, preferences: defaults))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
        let table = try #require(tableView(in: host))
        #expect(table.numberOfRows >= 3)
        #expect(learning.senseID == initial.senses[0].id)
        // Select the other row through the real SwiftUI List's AppKit backing, then publish
        // an archive revision exactly as a completed model request does.
        table.selectRowIndexes(IndexSet(integer: table.selectedRow == 1 ? 2 : 1), byExtendingSelection: false)
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
        let input = try #require(learning.explanations.values.first?.input)
        #expect(input.context == "We walked along the bank.")
        await store.saveExplanation(.init(id: UUID(), input: input, language: .english,
            result: .init(meaning: "The edge of a river", explanation: "A geographical feature."), model: "fixture", createdAt: Date()))
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
        #expect(learning.explanations.values.first?.input == input)
        #expect(learning.senseID == initial.senses[1].id)
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_UI_SENSE_REVIEW"] == "1"))
    func nativeSenseActionsCanBeReviewedWithoutUserData() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let fixtures = [("I went to the bank.", "Financial institution"),
                        ("The bank opened early.", "A financial institution"),
                        ("We sat beside the bank.", "River edge")]
        for (text, meaning) in fixtures {
            let capture = VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
                example: VocabularyPolicy.example(text: text, ranges: [(text as NSString).range(of: "bank")], language: .english))
            await store.save(capture)
            await store.saveExplanation(.init(id: UUID(), input: LearningExplanationPolicy.input(capture), language: .english,
                result: .init(meaning: meaning, explanation: "A contextual explanation from an isolated acceptance fixture."),
                model: "fixture", createdAt: Date()))
        }
        let entry = try #require(store.entries.first)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let learning = VocabularyNotebookSession(provider: LearningLexiconService(resourceURL: nil))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech,
            selectedID: entry.id, selectedSenseID: entry.senses[0].id, learning: learning, preferences: defaults))
        let window = NSWindow(contentRect: .init(x: 120, y: 160, width: 1040, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.title = "Lingrove vocabulary sense acceptance"
        window.level = .floating; window.makeKeyAndOrderFront(nil)
        defer { learning.cancel(); window.close() }
        try await Task.sleep(for: .milliseconds(250))
        #expect(learning.senseID == entry.senses[0].id)
        #expect(entry.senses.count == 3 && store.entries[0].examples.count == 3)
        let duration = Int(LingroveCompatibility.processEnvironment["LINGROVE_UI_REVIEW_SECONDS"] ?? "45") ?? 45
        try await Task.sleep(for: .seconds(min(240, max(1, duration))))
    }

    private func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { tableView(in: $0) }.first
    }

    @Test func libraryAndEditorRenderWithoutReadingRealUserData() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let text = "Please keep me posted on the progress."
        let capture = VocabularyCapture(expression: "keep me posted", dictionaryForm: "keep someone posted", language: .english,
            kind: .expression, meaning: "随时告诉我最新进展", example: VocabularyPolicy.example(text: text,
                ranges: [(text as NSString).range(of: "keep me posted")], language: .english))
        await store.save(capture)
        let before = try #require(store.entries.first)
        var annotated = before
        let image = try await store.prepareImage(VocabularyImageTestFixture.png())
        annotated.senses[0].content = [.init(content: .text(.init(text: "Keep someone informed", bold: true))),
            .init(content: .image(image.reference, caption: "An explanation image"))]
        #expect(await store.update(annotated, basedOn: before, importedImages: [image.reference.filename: image.data]))
        let entry = try #require(store.entries.first)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech,
            selectedID: entry.id, preferences: defaults))
        window.contentView = view
        window.orderFrontRegardless()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)); view.layoutSubtreeIfNeeded() }
        #expect(view.fittingSize.width >= 760)
        #expect(!speech.isPlaying(SpeechTarget(ownerID: entry.id, itemID: "vocabulary.expression")))
        let output = URL(fileURLWithPath: LingroveCompatibility.processEnvironment["LINGROVE_UI_SCREENSHOT_DIR"] ??
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
        #expect(window.contentView?.fittingSize.width == 680)
        if let editor = window.contentView, let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("content-editor.png"))
        }
    }
}
