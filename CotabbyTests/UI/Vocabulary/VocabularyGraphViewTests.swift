import AppKit
import SwiftUI
import Testing
@testable import Cotabby

@MainActor
@Suite(.serialized)
struct VocabularyGraphViewTests {
    @Test func settingsPersistAndResetInAnIsolatedSuite() throws {
        let suite = "GraphTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VocabularyGraphPresentation(defaults: defaults)
        model.settings.nodeSize = 22; model.settings.linkDistance = 175
        let restored = VocabularyGraphPresentation(defaults: defaults)
        #expect(restored.settings.nodeSize == 22 && restored.settings.linkDistance == 175)
        restored.settings = .init()
        #expect(VocabularyGraphPresentation(defaults: defaults).settings == VocabularyGraphSettings())
    }

    @Test func graphBrowserExpandsHeadwordAndReusesSenseDetails() async throws {
        let suite = "GraphTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("graph", forKey: "vocabularyBrowserMode")
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.save(.init(expression: "light", dictionaryForm: "light", language: .english, kind: .word, meaning: "光；光线"))
        let entryID = try #require(store.entries.first?.id)
        _ = await store.createSense(entryID: entryID)
        let baseline = try #require(store.entries.first)
        var entry = baseline
        entry.senses[1].meaning = "轻的；重量小"
        #expect(await store.update(entry, basedOn: baseline))
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech, preferences: defaults))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
        let canvas = try #require(findCanvas(host))
        #expect(window.toolbar != nil)
        #expect(canvas.accessibilityChildren()?.count == 1)
        canvas.activate(.headword(entryID))
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
        #expect(canvas.accessibilityChildren()?.count == 3)
        let accessible = try #require(canvas.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(accessible.isAccessibilityEnabled())
        canvas.activate(.sense(.init(entryID: entryID, senseID: entry.senses[1].id)))
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
        #expect(findCanvas(host) != nil)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/vocabulary-graph/acceptance")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("graph-detail.png"))
        }
        canvas.activate(.headword(entryID))
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded() }
        #expect(canvas.accessibilityChildren()?.count == 1)
    }

    @Test func quickNativeDragReachesWorkerBeforeCooling() async throws {
        let suite = "GraphTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VocabularyGraphPresentation(defaults: defaults)
        model.settings.center = 0; model.settings.repulsion = 10
        let canvas = VocabularyGraphCanvasView(presentation: model)
        let id = UUID()
        canvas.update(snapshot: .init(nodes: [.init(id: .headword(id), label: "word")], headwordCount: 1),
                      selection: nil, select: { _ in })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { canvas.suspend(); window.close() }
        window.orderFrontRegardless()
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(40)) }
        let element = try #require(canvas.accessibilityChildren()?.first as? NSAccessibilityElement)
        let before = element.accessibilityFrame()
        let start = window.convertPoint(fromScreen: CGPoint(x: before.midX, y: before.midY))
        let end = CGPoint(x: start.x + 80, y: start.y + 40)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0.5))
        }
        // These are direct events in an isolated test view, not global OS input. No async
        // suspension occurs between drag and release, reproducing a gesture shorter than a tick.
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        canvas.mouseUp(with: try event(.leftMouseUp, end))
        try await Task.sleep(for: .milliseconds(100))
        let after = element.accessibilityFrame()
        #expect(abs((after.midX - before.midX) - 80) < 2)
        #expect(abs((after.midY - before.midY) - 40) < 2)
    }

    private func findCanvas(_ view: NSView) -> VocabularyGraphCanvasView? {
        if let canvas = view as? VocabularyGraphCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas($0) }.first
    }

    @Test func searchNavigationStopsInitialFitWhileLayoutIsSettling() async throws {
        let suite = "GraphTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VocabularyGraphPresentation(defaults: defaults)
        let canvas = VocabularyGraphCanvasView(presentation: model)
        let ids = [UUID(), UUID(), UUID()]
        var snapshot = VocabularyGraphSnapshot(nodes: ids.map { .init(id: .headword($0), label: "word") }, headwordCount: 3)
        canvas.update(snapshot: snapshot, selection: nil, select: { _ in })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { canvas.suspend(); window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        #expect(canvas.isAnimating && model.fitsInitialLayout)
        snapshot.matches = [.headword(ids[0])]; snapshot.searchQuery = "word"
        canvas.update(snapshot: snapshot, selection: nil, select: { _ in })
        #expect(!model.fitsInitialLayout)
        let navigatedCamera = model.camera
        let count = canvas.renderedFrameCount
        try await Task.sleep(for: .milliseconds(120))
        #expect(canvas.renderedFrameCount > count)
        #expect(model.camera == navigatedCamera)
    }

    @Test func nativeCanvasCoolsAndStopsWhenRemoved() async throws {
        let suite = "GraphTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VocabularyGraphPresentation(defaults: defaults)
        let canvas = VocabularyGraphCanvasView(presentation: model)
        let ids = [UUID(), UUID(), UUID()]
        let snapshot = VocabularyGraphSnapshot(nodes: ids.map { .init(id: .headword($0), label: "word") }, headwordCount: 3)
        canvas.update(snapshot: snapshot, selection: nil, select: { _ in })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { canvas.suspend(); window.close() }
        window.orderFrontRegardless()
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            if !canvas.isAnimating && canvas.renderedFrameCount > 1 { break }
        }
        #expect(canvas.renderedFrameCount > 1)
        #expect(!canvas.isAnimating)
        let count = canvas.renderedFrameCount
        try await Task.sleep(for: .milliseconds(120))
        #expect(canvas.renderedFrameCount == count)
        #expect(canvas.accessibilityChildren()?.count == 3)
        canvas.suspend(); window.contentView = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(!canvas.isAnimating)
    }
}
