import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LingroveNotebook
import LingroveNotebookSync
import XCTest
import UniformTypeIdentifiers
@testable import LingroveNotebookEngine

/// Exercises real SQLite jobs, generation fences and the shared on-disk cache.
/// Network/transport behavior is covered separately by the opt-in HTTP test.
@MainActor
final class LingroveNotebookMediaQueueIntegrationTests: XCTestCase {
    // PNG transfer failures, retry, cancellation and restart preserve their original resource intent
    func testDurableTransferControl() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let image = try Self.image()
        let binding = try f.binding()
        var queue = LingroveNotebookMediaQueueStore(core: f.db.core)
        let queued = try requireNotebookMedia(try queue.enqueue([image.reference], direction: .download, consumer: "window:fixture", binding: binding).first)
        let first = try queue.claim(queued.id, binding: binding)
        var corrupt = image.data; corrupt[corrupt.startIndex + 20] ^= 1
        XCTAssertThrowsError(try queue.complete(first, remoteAssetID: UUID(), binding: binding, received: (image.reference, corrupt)))
        XCTAssertTrue(try queue.jobs(binding: binding)[0].state == .transferring)
        try queue.fail(first, state: .failed, binding: binding)
        try f.reopen(); queue = .init(core: f.db.core)
        XCTAssertTrue(try queue.jobs(binding: binding)[0].state == .failed)
        XCTAssertThrowsError(try queue.claim(queued.id, binding: binding)) { error in XCTAssertEqual(error as? LingroveNotebookMediaError, LingroveNotebookMediaError.incomplete(.failed)) }
        try queue.control(queued.id, cancel: true, binding: binding)
        try f.reopen(); queue = .init(core: f.db.core)
        XCTAssertThrowsError(try queue.claim(queued.id, binding: binding)) { error in XCTAssertEqual(error as? LingroveNotebookMediaError, LingroveNotebookMediaError.incomplete(.cancelled)) }
        XCTAssertThrowsError(try queue.complete(first, remoteAssetID: UUID(), binding: binding, received: (image.reference, image.data)))
        XCTAssertTrue(try queue.jobs(binding: binding)[0].state == .cancelled)
        XCTAssertTrue(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_media_assets", values: []) == 0)
        try queue.control(queued.id, cancel: false, binding: binding)
        let retry = try queue.claim(queued.id, binding: binding)
        try queue.complete(retry, remoteAssetID: UUID(), binding: binding, received: (image.reference, image.data))
        try f.reopen(); queue = .init(core: f.db.core)
        XCTAssertTrue(try queue.jobs(binding: binding)[0].state == .ready)
        XCTAssertTrue(try queue.jobs(binding: binding)[0].attempts == 2)
        let scope = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        XCTAssertTrue(try LingroveNotebookMediaStore(core: f.db.core).image(image.reference, scope: scope) == image.data)
        XCTAssertTrue(try f.db.core.scalarInt(sql: "SELECT count(*) FROM media_transfer_queue", values: []) == 0)
        try queue.release(consumer: "window:fixture", binding: binding)
        XCTAssertTrue(try queue.prune(binding: binding) == [image.reference])
        XCTAssertTrue(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_media_releases", values: []) == 1)
        try queue.replacePins([image.reference], workspaceID: f.workspace, consumer: "draft:re-added")
        XCTAssertTrue(try queue.prune(binding: binding).isEmpty)
        XCTAssertTrue(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_media_releases", values: []) == 0)
        XCTAssertTrue(try f.db.core.scalarInt(sql: "SELECT count(*) FROM media_blob_cache", values: []) == 1)
    }

    // An old process/attempt/account cannot complete a new transfer or borrow another workspace's cached hash
    func testRestartAndAccountFences() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let image = try Self.image(), binding = try f.binding()
        let queue = LingroveNotebookMediaQueueStore(core: f.db.core)
        let job = try requireNotebookMedia(try queue.enqueue([image.reference], direction: .download, consumer: "download:old", binding: binding).first)
        let dead = try queue.claim(job.id, binding: binding, processID: "terminated-process")
        let resumed = try queue.claim(job.id, binding: binding, processID: "new-process")
        XCTAssertTrue(dead.attemptID != resumed.attemptID)
        XCTAssertThrowsError(try queue.complete(dead, remoteAssetID: nil, binding: binding, received: (image.reference, image.data))) { error in XCTAssertEqual(error as? LingroveNotebookMediaError, LingroveNotebookMediaError.staleAttempt) }
        try queue.complete(resumed, remoteAssetID: nil, binding: binding, received: (image.reference, image.data))
        let imageScope = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        let other = UUID().uuidString.lowercased()
        try f.addWorkspace(other)
        try f.db.updateCloudSettings(cloudState: .linked, linkedUserId: f.owner, linkedWorkspaceId: other, activeWorkspaceId: other, linkedEmail: nil)
        let otherBinding = try f.binding(workspace: other)
        let otherQueue = LingroveNotebookMediaQueueStore(core: f.db.core)
        let foreign = try requireNotebookMedia(try otherQueue.enqueue([image.reference], direction: .download, consumer: "same-hash", binding: otherBinding).first)
        let claimed = try otherQueue.claim(foreign.id, binding: otherBinding)
        XCTAssertThrowsError(try otherQueue.complete(claimed, remoteAssetID: nil, binding: otherBinding))
        XCTAssertThrowsError(try queue.jobs(binding: binding))
        try f.db.updateCloudSettings(cloudState: .linked, linkedUserId: f.owner, linkedWorkspaceId: f.workspace, activeWorkspaceId: f.workspace, linkedEmail: nil)
        XCTAssertThrowsError(try queue.jobs(binding: binding))
        let fresh = try f.binding()
        XCTAssertTrue(fresh.generation != binding.generation)
        XCTAssertThrowsError(try LingroveNotebookMediaStore(core: f.db.core).image(image.reference, scope: imageScope))
        XCTAssertTrue(try LingroveNotebookMediaStore(core: f.db.core).ownedImage(image.reference, workspaceId: f.workspace) == image.data)
    }

    // Current, draft and journal pins retain media without deleting shared Card/blob rows
    func testReferenceRetention() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let image = try Self.image(), initial = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        let saved = try f.db.saveLingroveNotebook(Self.document(image.reference), basedOn: initial, images: [image.reference.filename: image.data])
        let binding = try f.binding(), queue = LingroveNotebookMediaQueueStore(core: f.db.core)
        let job = try requireNotebookMedia(try queue.enqueue([image.reference], direction: .upload, consumer: "upload:pending", binding: binding).first)
        let claim = try queue.claim(job.id, binding: binding)
        try queue.complete(claim, remoteAssetID: UUID(), binding: binding)
        try queue.control(job.id, cancel: true, binding: binding)
        try queue.replacePins([image.reference], workspaceID: f.workspace, consumer: "draft:open")
        _ = try f.db.saveLingroveNotebook(VocabularyDocument(), basedOn: saved)
        try queue.release(consumer: "upload:pending", binding: binding)
        XCTAssertTrue(try queue.prune(binding: binding).isEmpty)
        try queue.release(consumer: "draft:open", binding: binding)
        XCTAssertTrue(try queue.prune(binding: binding).isEmpty, "Unacknowledged journal images must remain retained")
        XCTAssertTrue(try LingroveNotebookMediaStore(core: f.db.core).ownedImage(image.reference, workspaceId: f.workspace) == image.data)
        XCTAssertTrue(try f.db.core.scalarInt(sql: "SELECT count(*) FROM media_assets WHERE sha256=?", values: [.text(image.reference.digest)]) == 1)
        // Removed references must retire obsolete queued/failed/cancelled work
        // too, while live attempts continue owning their finite lease.
        let orphan = try NotebookMediaDatabaseFixture(); defer { orphan.cleanUp() }
        let orphanBinding = try orphan.binding(), orphanQueue = LingroveNotebookMediaQueueStore(core: orphan.db.core)
        for state in [LingroveNotebookMediaState.queued, .missing, .failed, .cancelled] {
            let abandoned = try requireNotebookMedia(try orphanQueue.enqueue([image.reference], direction: .download,
                consumer: "window:orphan", binding: orphanBinding).first)
            if state == .cancelled { try orphanQueue.control(abandoned.id, cancel: true, binding: orphanBinding) }
            else if state != .queued {
                let active = try orphanQueue.claim(abandoned.id, binding: orphanBinding)
                try orphanQueue.fail(active, state: state, binding: orphanBinding)
            }
            XCTAssertTrue(try orphanQueue.prune(binding: orphanBinding).isEmpty)
            try orphanQueue.release(consumer: "window:orphan", binding: orphanBinding)
            XCTAssertTrue(try orphanQueue.prune(binding: orphanBinding) == [image.reference])
            XCTAssertTrue(try orphanQueue.jobs(binding: orphanBinding).isEmpty)
            try orphanQueue.acknowledgeRelease(image.reference, binding: orphanBinding)
        }
        let pending = try requireNotebookMedia(try orphanQueue.enqueue([image.reference], direction: .download,
            consumer: "window:live", binding: orphanBinding).first)
        _ = try orphanQueue.claim(pending.id, binding: orphanBinding)
        try orphanQueue.release(consumer: "window:live", binding: orphanBinding)
        XCTAssertTrue(try orphanQueue.prune(binding: orphanBinding).isEmpty, "A live transfer still owns its finite lease")
        try orphanQueue.control(pending.id, cancel: true, binding: orphanBinding)
        XCTAssertTrue(try orphanQueue.prune(binding: orphanBinding) == [image.reference])

    }

    static func document(_ reference: VocabularyImageReference) -> VocabularyDocument {
        let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
        let sense = VocabularySense(id: UUID(), meaning: "an original image", meaningLanguage: .english, meaningOrigin: .user,
            isSavedWithoutContext: true,
            content: [.init(id: UUID(), content: .image(reference, caption: "local PNG fixture"))],
            createdAt: now, updatedAt: now)
        return VocabularyDocument(entries: [.init(id: UUID(), expression: "picture", dictionaryForm: "picture", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)])
    }
    static func image() throws -> VocabularyPreparedImage {
        let pixels: [UInt8] = [220, 40, 80, 255, 30, 140, 210, 255]
        let provider = try requireNotebookMedia(CGDataProvider(data: Data(pixels) as CFData))
        let image = try requireNotebookMedia(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let output = try requireNotebookMedia(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        try requireNotebookMedia(CGImageDestinationFinalize(output))
        let bytes = data as Data
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(reference: .init(digest: digest, width: 2, height: 1, byteCount: bytes.count), data: bytes)
    }
}

@MainActor
final class NotebookMediaDatabaseFixture {
    let directory: URL
    let url: URL
    let workspace: String
    let owner: String
    let book: UUID
    let replica: UUID
    var db: LocalDatabase
    init(workspace: String = UUID().uuidString.lowercased(), owner: String = "notebook-media-owner", installation: String? = nil) throws {
        self.workspace = workspace; self.owner = owner; book = UUID(); replica = UUID()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-media-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("primary.sqlite")
        db = try LocalDatabase(databaseURL: url)
        try addWorkspace(workspace)
        if let installation { try db.core.execute(sql: "UPDATE app_local_settings SET installation_id=? WHERE settings_id=1", values: [.text(installation)]) }
        try db.updateCloudSettings(cloudState: .linked, linkedUserId: owner, linkedWorkspaceId: workspace, activeWorkspaceId: workspace, linkedEmail: nil)
        _ = try db.loadLingroveNotebook(workspaceId: workspace)
    }
    func addWorkspace(_ id: String) throws {
        try db.core.execute(sql: """
            INSERT INTO workspaces(workspace_id,name,created_at,fsrs_client_updated_at,fsrs_last_modified_by_replica_id,fsrs_last_operation_id)
            VALUES(?,'Notebook media fixture',?,?,?,?)
            """, values: [.text(id), .text(nowIsoTimestamp()), .text(nowIsoTimestamp()), .text(replica.uuidString), .text(UUID().uuidString)])
        _ = try db.loadLingroveNotebook(workspaceId: id)
    }
    func binding(workspace: String? = nil) throws -> LingroveNotebookWindowBinding {
        try db.captureLingroveNotebookWindowBinding(scope: .init(ownerUserID: owner, workspaceID: UUID(uuidString: workspace ?? self.workspace)!, notebookID: book, replicaID: replica))
    }
    func reopen() throws { try db.close(); db = try LocalDatabase(databaseURL: url) }
    func cleanUp() { try? db.close(); try? FileManager.default.removeItem(at: directory) }
}

/// XCTest's app-hosted runner owns assertion reporting; optional/condition
/// requirements throw so fixture setup cannot continue after a failed check.
func requireNotebookMedia<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}
func requireNotebookMedia(_ condition: Bool, _ message: String = "Required condition failed", file: StaticString = #filePath, line: UInt = #line) throws {
    guard condition else {
        XCTFail(message, file: file, line: line)
        throw NotebookMediaTestRequirement.failed
    }
}
private enum NotebookMediaTestRequirement: Error { case failed }
