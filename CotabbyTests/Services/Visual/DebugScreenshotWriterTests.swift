import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import Cotabby

/// Exercise real thread ownership with a blocked sink: filesystem stalls must not become UI
/// waits, executor starvation, an unbounded image queue, or a shutdown barrier.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DebugScreenshotWriterTests {
    @Test func blockedStorageKeepsOnlyTheLatestPendingCaptureAndLeavesExecutorsAvailable() async throws {
        let probe = DebugScreenshotProbe(holdsFirstWrite: true)
        let writer = DebugScreenshotWriter(minimumInterval: 0, writeCapture: { probe.write($0) })
        defer { writer.shutdown(); probe.release() }
        let image = try makeImage()
        #expect(writer.submit(image: image, text: "text", applicationName: "first"))
        try await waitUntil { probe.names == ["first"] }
        for index in 1...200 { writer.submit(image: image, text: "text", applicationName: String(index)) }
        #expect(probe.names == ["first"] && probe.completed == 0)
        let canary = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: true) }
        }
        #expect(canary && Thread.isMainThread)
        probe.release()
        try await waitUntil { probe.completed == 2 }
        #expect(probe.names == ["first", "200"])
        #expect(probe.workerThreads.count == 1 && !probe.usedMainThread)
    }

    @Test func samplingAdmitsAtMostOneCaptureEveryFiveSeconds() throws {
        let clock = DebugScreenshotClock()
        let writer = DebugScreenshotWriter(now: { clock.value }, writeCapture: { _ in })
        defer { writer.shutdown() }
        let image = try makeImage()
        #expect(writer.submit(image: image, text: "first", applicationName: "Test"))
        clock.value = 4.99
        #expect(!writer.submit(image: image, text: "sampled out", applicationName: "Test"))
        clock.value = 5
        #expect(writer.submit(image: image, text: "second", applicationName: "Test"))
    }

    @Test func failedWriteDoesNotStopTheNextCapture() async throws {
        let probe = DebugScreenshotProbe()
        let writer = DebugScreenshotWriter(minimumInterval: 0, writeCapture: { capture in
            probe.write(capture)
            if capture.applicationName == "fail" { throw CocoaError(.fileWriteNoPermission) }
        }, onFailure: { probe.recordFailure() })
        defer { writer.shutdown() }
        let image = try makeImage()
        writer.submit(image: image, text: "text", applicationName: "fail")
        try await waitUntil { probe.failures == 1 }
        writer.submit(image: image, text: "text", applicationName: "recover")
        try await waitUntil { probe.completed == 2 }
        #expect(probe.names == ["fail", "recover"] && probe.failures == 1)
    }

    @Test func shutdownReturnsDuringAStallAndDiscardsPendingDiagnostics() async throws {
        let probe = DebugScreenshotProbe(holdsFirstWrite: true)
        let writer = DebugScreenshotWriter(minimumInterval: 0, writeCapture: { probe.write($0) })
        defer { writer.shutdown(); probe.release() }
        let image = try makeImage()
        writer.submit(image: image, text: "text", applicationName: "active")
        try await waitUntil { probe.names == ["active"] }
        writer.submit(image: image, text: "text", applicationName: "pending")
        writer.shutdown()
        #expect(probe.completed == 0)
        #expect(!writer.submit(image: image, text: "text", applicationName: "after shutdown"))
        probe.release()
        try await waitUntil { probe.completed == 1 }
        #expect(probe.names == ["active"])
    }

    @Test func realStorageRetainsMatchingPNGAndTextPairsInItsOwnApplicationFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DebugScreenshots-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var store = DebugScreenshotStore(directory: root)
        store.maximumCapturesPerApp = 3
        let storage = store
        let probe = DebugScreenshotProbe()
        let writer = DebugScreenshotWriter(minimumInterval: 0, writeCapture: { capture in
            try storage.write(capture)
            probe.write(capture)
        })
        defer { writer.shutdown() }
        let image = try makeImage()
        for index in 0..<5 {
            writer.submit(image: image, text: String(index), applicationName: "../Test/..")
            try await waitUntil { probe.completed == index + 1 }
        }
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Test"),
            includingPropertiesForKeys: nil)
        let images = files.filter { $0.pathExtension == "png" }
        let texts = files.filter { $0.pathExtension == "txt" }
        #expect(images.count == 3 && texts.count == 3)
        #expect(Set(images.map { $0.deletingPathExtension().lastPathComponent }) ==
                Set(texts.map { $0.deletingPathExtension().lastPathComponent }))
        #expect(try Set(texts.map { try String(contentsOf: $0, encoding: .utf8) }) == ["2", "3", "4"])
        #expect(!probe.usedMainThread)
    }

    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), "Diagnostic writer did not reach the expected state")
    }
}

/// Shared test evidence crosses the disk worker and MainActor. Only the first write may wait;
/// releasing it lets the test prove that queued intermediate images were actually discarded.
nonisolated final class DebugScreenshotProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var held: Bool
    private var recordedNames: [String] = []
    private var finished = 0
    private var failed = 0
    private var threads: Set<UInt32> = []
    private var mainThread = false
    init(holdsFirstWrite: Bool = false) { held = holdsFirstWrite }
    var names: [String] { condition.withLock { recordedNames } }
    var completed: Int { condition.withLock { finished } }
    var failures: Int { condition.withLock { failed } }
    var workerThreads: Set<UInt32> { condition.withLock { threads } }
    var usedMainThread: Bool { condition.withLock { mainThread } }
    func write(_ capture: DebugScreenshotWriter.Capture) {
        condition.lock()
        recordedNames.append(capture.applicationName)
        threads.insert(pthread_mach_thread_np(pthread_self()))
        mainThread = mainThread || Thread.isMainThread
        while held && recordedNames.count == 1 { condition.wait() }
        finished += 1
        condition.unlock()
    }
    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
    func recordFailure() { condition.withLock { failed += 1 } }
}

/// Deterministic admission timing keeps sampling tests independent of disk speed or CPU load.
private nonisolated final class DebugScreenshotClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = 0.0
    var value: Double {
        get { lock.withLock { instant } }
        set { lock.withLock { instant = newValue } }
    }
}
