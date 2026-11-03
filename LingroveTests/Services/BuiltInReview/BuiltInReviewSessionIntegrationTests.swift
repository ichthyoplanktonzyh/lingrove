import AppKit
import CryptoKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// Native components and real SQLite form one short review journey. These tests use an
/// isolated repository and offscreen window, never global input, the user's app or account.
@Suite(.serialized)
@MainActor
struct BuiltInReviewSessionIntegrationTests {
    @Test("Prepare/cancel, explicit enrollment, window keyboard rating, reopen and persisted undo")
    func nativeReviewJourney() async throws {
        let fixture = try BuiltInReviewMacFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        let windowController = BuiltInReviewWindowController(session: session)
        windowController.prepareWindow()
        defer { windowController.shutdown() }
        let window = try #require(windowController.window)
        session.open(selection: fixture.selection)
        await session.waitForIdle()
        var content = try #require(session.content)
        #expect(content.statistics.exercises == 0)
        session.prepare(selection: fixture.selection, basedOn: content)
        var cancelled = try #require(session.draft)
        fixture.repository.publishChange()
        await session.waitForIdle()
        #expect(session.draft?.id == cancelled.id, "An unchanged sync ACK must not discard an editor")
        cancelled.front = "Cancelled prompt"
        session.draft = nil
        #expect(try fixture.repository.engine.loadActiveCardCount(workspaceId: content.scope.workspaceId) == 0)
        session.prepare(selection: fixture.selection, basedOn: content)
        var prepared = try #require(session.draft)
        if let example = content.scope.document.entries.first?.senses.first?.examples.first {
            prepared.chooseExample(example.id)
            #expect(prepared.exampleID == example.id && prepared.front.contains("boat"))
        }
        prepared.front = "My native prompt"
        let preparationHost = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        preparationHost.isReleasedWhenClosed = false
        preparationHost.contentView = NSHostingView(rootView: BuiltInReviewPreparationView(session: session, draft: prepared))
        try await capture(preparationHost, name: "native-preparation", minimumWidth: 620, minimumHeight: 650)
        preparationHost.close()
        session.save(prepared)
        await session.waitForIdle()
        content = try #require(session.content)
        #expect(content.statistics.activeSenses == 1 && content.statistics.exercises == 1)
        #expect(content.queue.first?.frontText == "My native prompt")
        session.start()
        let reveal = try key(" ", window: window)
        let digit = try key("3", window: window)
        let tab = try key("\t", window: window)
        #expect(windowController.keyboardAction(for: digit, isKeyWindow: true) == nil)
        #expect(windowController.keyboardAction(for: reveal, isKeyWindow: false) == nil)
        windowController.handle(try #require(windowController.keyboardAction(for: reveal, isKeyWindow: true)))
        #expect(windowController.keyboardAction(for: digit, isKeyWindow: true) == .rate(.good))
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 80, height: 40))
        let hostedRoot = try #require(window.contentView)
        // An NSHostingView owns its subviews. Give the responder check its own temporary
        // native content view rather than injecting a child into SwiftUI's private hierarchy.
        window.contentView = editor
        #expect(window.makeFirstResponder(editor))
        #expect(windowController.keyboardAction(for: digit, isKeyWindow: true) == nil)
        #expect(windowController.keyboardAction(for: tab, isKeyWindow: true) == nil)
        window.makeFirstResponder(nil)
        window.contentView = hostedRoot
        try await capture(window, name: "native-answer")
        windowController.handle(try #require(windowController.keyboardAction(for: digit, isKeyWindow: true)))
        await session.waitForIdle()
        content = try #require(session.content)
        #expect(content.statistics.ratingRecords == 1 && content.review.groups[fixture.selection.senseID]?.cards.first?.reps == 1)
        #expect(session.practice?.answered == 1)
        let ratedID = try #require(content.review.groups[fixture.selection.senseID]?.cards.first).cardId
        session.close()
        session.open(selection: nil)
        await session.waitForIdle()
        content = try #require(session.content)
        #expect(content.queue.isEmpty && content.statistics.ratingRecords == 1)
        let undo = try #require(session.undoAction(cardID: ratedID, basedOn: content))
        session.undo(undo)
        await session.waitForIdle()
        content = try #require(session.content)
        #expect(content.queue.first?.reps == 0 && content.queue.first?.frontText == "My native prompt")
        #expect(content.statistics.ratingRecords == 1 && content.statistics.undoneRatings == 1)
        var openedSource: VocabularySelection?
        session.onOpenSource = { openedSource = $0 }
        let group = try #require(content.review.groups[fixture.selection.senseID])
        let sourceCard = try #require(group.cards.first)
        let context = try #require(session.context(card: sourceCard, group: group, content: content))
        session.openSource(context)
        #expect(openedSource == fixture.selection)
        try await capture(window, name: "native-overview-reopened")
        window.setContentSize(.init(width: 760, height: 560))
        try await capture(window, name: "native-overview-minimum")
    }

    @Test("A temporarily unavailable active scope clears loading and can be retried")
    func unavailableScopeDoesNotLeavePermanentLoading() async throws {
        let fixture = try BuiltInReviewMacFixture(); defer { fixture.cleanUp() }
        let workspace = try fixture.repository.snapshot().workspaceId
        fixture.session.open(selection: nil)
        #expect(fixture.session.isRefreshing)
        try fixture.repository.engine.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil,
            linkedWorkspaceId: nil, activeWorkspaceId: nil, linkedEmail: nil)
        fixture.repository.publishChange()
        #expect(!fixture.session.isRefreshing && !fixture.session.isBusy && fixture.session.content == nil)
        try fixture.repository.engine.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil,
            linkedWorkspaceId: nil, activeWorkspaceId: workspace, linkedEmail: nil)
        fixture.repository.publishChange()
        await fixture.session.waitForIdle()
        #expect(fixture.session.content != nil && !fixture.session.isBusy && fixture.session.message == nil)
    }

    @Test("Repository changes close stale draft/question; stale actor writes never borrow fresh generation")
    func externalChangesAndGenerationFence() async throws {
        let fixture = try BuiltInReviewMacFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.open(selection: fixture.selection)
        await session.waitForIdle()
        let initial = try #require(session.content)
        session.prepare(selection: fixture.selection, basedOn: initial)
        let stale = try #require(session.draft)
        var changed = initial.scope.document
        changed.entries[0].senses[0].meaning = "Changed by another window"
        _ = try fixture.repository.engine.saveLingroveNotebook(changed, basedOn: initial.scope)
        fixture.repository.publishChange()
        #expect(session.draft == nil)
        await session.waitForIdle()
        #expect(session.content?.scope.revision != initial.scope.revision)
        let io = BuiltInReviewIO(databaseURL: fixture.repository.databaseURL, mediaDirectoryURL: fixture.repository.mediaDirectoryURL)
        do { try await io.perform(.save(stale)); Issue.record("A stale preparation wrote after a source revision change") }
        catch { #expect(try fixture.repository.engine.loadActiveCardCount(workspaceId: initial.scope.workspaceId) == 0) }
        let fresh = try #require(session.content)
        session.enrollDefault(selection: fixture.selection, basedOn: fresh)
        await session.waitForIdle()
        session.start()
        #expect(session.practice?.phase.context != nil)
        let beforeSwitch = try #require(session.content)
        try fixture.repository.engine.updateCloudSettings(cloudState: .linked, linkedUserId: "review-validation-a",
            linkedWorkspaceId: initial.scope.workspaceId, activeWorkspaceId: initial.scope.workspaceId, linkedEmail: nil)
        try fixture.repository.engine.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil,
            linkedWorkspaceId: nil, activeWorkspaceId: initial.scope.workspaceId, linkedEmail: nil)
        fixture.repository.publishChange()
        #expect(session.practice == nil)
        await session.waitForIdle()
        let afterSwitch = try #require(session.content)
        #expect(afterSwitch.scope.generation != beforeSwitch.scope.generation)
        #expect(session.route == .overview)
        #expect(afterSwitch.statistics.ratingRecords == 0)
    }

    @Test("Saved managed PNGs are local-only and remain bound to the original card scope")
    func savedMediaDoesNotLoadRemoteImages() async throws {
        let fixture = try BuiltInReviewMacFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.open(selection: fixture.selection)
        await session.waitForIdle()
        session.enrollDefault(selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        var content = try #require(session.content)
        var group = try #require(content.review.groups[fixture.selection.senseID])
        var card = try #require(group.cards.first)
        let png = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixel = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        for x in 0..<8 { for y in 0..<8 { png.setColor(pixel, atX: x, y: y) } }
        let bytes = try #require(png.representation(using: .png, properties: [:]))
        let decoded = try #require(NSBitmapImageRep(data: bytes))
        let color = try #require(decoded.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(color.alphaComponent > 0.9 && color.blueComponent > color.redComponent)
        #expect(NSImage(data: bytes)?.size == CGSize(width: 8, height: 8))
        if let path = ProcessInfo.processInfo.environment["LINGROVE_REVIEW_EVIDENCE_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: folder.appendingPathComponent("saved-asset.png"))
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let assetID = UUID().uuidString.lowercased()
        let asset = MediaAsset(mediaAssetId: assetID, workspaceId: content.scope.workspaceId, mimeType: "image/png",
            sizeBytes: Int64(bytes.count), sha256: digest, sourceUrl: "https://unused.invalid/image.png", createdAt: nowIsoTimestamp(),
            clientUpdatedAt: nowIsoTimestamp(), lastModifiedByReplicaId: "synthetic", lastOperationId: UUID().uuidString,
            updatedAt: nowIsoTimestamp(), deletedAt: nil)
        try fixture.repository.engine.mediaAssetStore.upsertMediaAsset(workspaceId: content.scope.workspaceId, mediaAsset: asset)
        let url = fixture.repository.mediaDirectoryURL.appendingPathComponent(try mediaBlobCacheRelativePath(sha256: digest))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        let link = try #require(content.review.links.first { $0.cardId == card.cardId })
        let face = "Local image\n\n" + (try managedImageMarkdownReference(mediaAssetId: assetID, altText: "fixture"))
            + "\n\n![Remote](https://unused.invalid/never-fetch.png)"
        try fixture.repository.engine.prepareNotebookExercise(link: link, card: card, snapshot: content.scope,
            exampleID: nil, input: .init(frontText: face, backText: card.backText, tags: card.tags),
            action: .init(content: content, selection: fixture.selection))
        fixture.repository.publishChange()
        await session.waitForIdle()
        content = try #require(session.content)
        group = try #require(content.review.groups[fixture.selection.senseID])
        card = try #require(group.cards.first)
        let context = try #require(session.context(card: card, group: group, content: content))
        let io = BuiltInReviewIO(databaseURL: fixture.repository.databaseURL, mediaDirectoryURL: fixture.repository.mediaDirectoryURL)
        let images = try await io.savedImages(context: context)
        #expect(images.count == 1 && images.first?.data == bytes && images.first?.id == assetID)
        session.start()
        await session.waitForIdle()
        #expect(session.images.count == 1)
        let windowController = BuiltInReviewWindowController(session: session)
        windowController.prepareWindow()
        defer { windowController.shutdown() }
        try await capture(try #require(windowController.window), name: "native-saved-png")
    }

    private func key(_ characters: String, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    private func capture(_ window: NSWindow, name: String, minimumWidth: CGFloat = 760,
                         minimumHeight: CGFloat = 560) async throws {
        guard let path = ProcessInfo.processInfo.environment["LINGROVE_REVIEW_EVIDENCE_DIR"] else { return }
        window.setFrameOrigin(.init(x: -3000, y: -3000))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(view.bounds.width >= minimumWidth && view.bounds.height >= minimumHeight && data.count > 1_000)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

/// The test owns one disposable file and app-style repository, just as the production graph
/// does. Its explicit teardown closes the UI before retiring SQLite; no real defaults or user
/// data directory is discovered by the fixture.
@MainActor
private final class BuiltInReviewMacFixture {
    let directory: URL
    let repository: MacNotebookRepository
    let session: BuiltInReviewSession
    let selection: VocabularySelection

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-review-mac-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = try .init(databaseURL: directory.appendingPathComponent("notebook.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("media"))
        let now = Date()
        let sense = VocabularySense(id: UUID(), meaning: "a sheltered place", meaningLanguage: .english,
            examples: [.init(id: UUID(), text: "The boat entered the harbor.", translation: "A saved context", ranges: [],
                completeness: .sentence, meaning: "a sheltered place", createdAt: now)],
            isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "harbor", dictionaryForm: "harbor", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)
        selection = .init(entryID: entry.id, senseID: sense.id)
        _ = try repository.engine.saveLingroveNotebook(.init(entries: [entry]), basedOn: repository.snapshot())
        session = .init(repository: repository)
    }

    func cleanUp() {
        session.close()
        try? repository.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
