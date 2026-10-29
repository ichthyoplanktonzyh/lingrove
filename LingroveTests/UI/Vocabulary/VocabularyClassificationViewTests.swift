import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Native hosted views verify the additive column against the existing notebook, with private
/// preferences and fixture data. Screenshots retain the actual SwiftUI layout for visual review.
@MainActor
@Suite(.serialized)
struct VocabularyClassificationViewTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_MEANING_WORKFLOW_REVIEW"] == "1"))
    func nativeMeaningTaskCancelsNestedChangesThenSavesOneCompleteTask() async throws {
        let archive = VocabularyArchive(url: nil)
        var document = VocabularyDocument()
        _ = try VocabularyPolicy.save(.init(expression: "Hello", dictionaryForm: "Hello", language: .english,
            kind: .word, meaning: "你好", meaningLanguage: .chinese), in: &document, now: Date())
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: [])
        _ = try await archive.commit(document)
        let store = VocabularyStore(archive: archive); await store.load()
        let category = try #require(document.classification.categories.first { $0.key == "function.social.greet" })
        let entry = try #require(store.entries.first), sense = try #require(entry.senses.first)
        for round in 0..<2 {
            var finished = false, savedID: UUID?
            let root = MeaningTaskHarness(store: store, categoryID: category.id,
                linking: .init(entryID: entry.id, senseID: sense.id), onSaved: { savedID = $0 }, onFinished: { finished = true })
            let host = NSHostingView(rootView: root.environment(\.vocabularyMeaningLanguages, [.chinese]))
            let window = makeWindow(host, width: 720, height: 720)
            window.title = "Meaning workflow review \(round + 1)"
            for _ in 0..<1_200 {
                if finished { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            window.close()
            #expect(finished)
            let snapshot = try await archive.load()
            if round == 0 {
                #expect(savedID == nil && snapshot.document == document)
            } else {
                let id = try #require(savedID)
                #expect(snapshot.document.semantics.nodes.first { $0.id == id }?.kind == .function)
                #expect(snapshot.document.semantics.mappings.contains { $0.nodeID == id && $0.senseID == sense.id })
                #expect(snapshot.document.classification.memberships.contains { $0.nodeID == id && $0.categoryID == category.id })
                #expect(snapshot.document.classification.categories.count == document.classification.categories.count + 1)
                #expect(snapshot.document.entries == document.entries)
            }
        }
    }

    @Test func categorySelectionFiltersMeaningsAndKeepsExistingBrowserControls() async throws {
        let suite = "CategoryUI-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("meaning", forKey: "vocabularyOrganization")
        defaults.set("list", forKey: "vocabularyBrowserMode")
        defaults.set(false, forKey: "vocabularyShowsUnexplored")
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
        let tables = tableViews(host)
        #expect(tables.count == 1)
        let outline = try #require(tables.first)
        let populatedCount = outline.numberOfRows
        #expect(populatedCount > 0)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await settle(host)
        #expect(defaults.string(forKey: "vocabularyOrganization") == "meaning")
        #expect(defaults.string(forKey: "vocabularyBrowserMode") == "list")
        try screenshot(host, named: "category-time-filter")
        defaults.set(true, forKey: "vocabularyShowsUnexplored")
        try await settle(host)
        let unexploredCount = try #require(tableViews(host).first).numberOfRows
        #expect(unexploredCount > populatedCount)
        try screenshot(host, named: "category-unexplored-visible")
        defaults.set("graph", forKey: "vocabularyBrowserMode")
        try await settle(host)
        try screenshot(host, named: "category-taxonomy-tree-graph")
        if let seconds = Int(LingroveCompatibility.processEnvironment["LINGROVE_CLASSIFICATION_UI_REVIEW_SECONDS"] ?? ""), seconds > 0 {
            try await Task.sleep(for: .seconds(min(seconds, 50)))
        }
        #expect(try await archive.load().document == document)
        defaults.set("list", forKey: "vocabularyBrowserMode")
        defaults.set("entry", forKey: "vocabularyOrganization")
        try await settle(host)
        #expect(tableViews(host).count == 1)
        try screenshot(host, named: "entry-browser-unchanged")
    }

    @Test func categoryEditorsRenderAtNativeSheetSizeInBothAppearances() async throws {
        let archive = VocabularyArchive(url: nil)
        var document = VocabularySemanticTests.fixture()
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: document.semantics.nodes)
        let category = try #require(document.classification.categories.first { $0.key == "content.time.timing" })
        document.classification.memberships = [.init(id: UUID(), nodeID: document.semantics.nodes[0].id, categoryID: category.id)]
        _ = try await archive.commit(document)
        let store = VocabularyStore(archive: archive); await store.load()
        try await paint(VocabularyCategoryEditor(store: store, parentID: category.id, preferredLanguages: [.chinese]),
            named: "new-category", dark: false)
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
        // Cached AppKit backgrounds can be transparent even in this light-appearance fixture.
        // Composite onto white so image viewers do not hide black labels on a black alpha canvas.
        let context = try #require(CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.draw(try #require(bitmap.cgImage), in: bounds)
        let opaque = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        try #require(opaque.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}

/// Acceptance-only sheet presentation lets the UI driver cancel the real editor and observe
/// onDismiss, while all data remains in a private in-memory archive owned by this test.
private struct MeaningTaskHarness: View {
    let store: VocabularyStore
    let categoryID: UUID
    let linking: VocabularySelection
    let onSaved: (UUID) -> Void
    let onFinished: () -> Void
    @State private var presented = true

    var body: some View {
        Color.clear.sheet(isPresented: $presented, onDismiss: onFinished) {
            VocabularyMeaningEditor(store: store, linking: linking, categoryID: categoryID,
                preferredLanguages: [.chinese], onSaved: onSaved)
        }
    }
}
