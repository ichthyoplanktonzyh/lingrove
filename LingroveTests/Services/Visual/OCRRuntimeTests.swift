import Foundation
import CoreGraphics
import Darwin
import Testing
import CryptoKit
@testable import Lingrove

/// Faults live only in disposable test executables. The production runtime is exercised through
/// its normal image-in/result-out interface, including real pipes, process death and cancellation.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OCRRuntimeTests {
    @Test func queuedCropExpiresWhileTheExistingNativeOperationRemainsActive() async throws {
        let fixture = try OCRRuntimeFixture(timeout: 5)
        defer { fixture.close() }
        let active = Task { try await fixture.recognize(903) }
        try await waitUntil { fixture.requests == [903] }
        let pid = fixture.pid
        await #expect(throws: OCRRuntimeFailure.timedOut) {
            try await fixture.recognize(400, purpose: .reading, deadline: ProcessInfo.processInfo.systemUptime + 0.03)
        }
        #expect(fixture.requests == [903] && fixture.pid == pid && fixture.events.count("retired") == 0)
        try fixture.release()
        _ = try await active.value
        #expect(try await fixture.recognize(902).lines.first?.text == "902")
        #expect(fixture.requests == [903, 902])
    }
    @Test func expiredCropDoesNotStartOrRetireAHealthyWorker() async throws {
        let fixture = try OCRRuntimeFixture()
        defer { fixture.close() }
        _ = try await fixture.recognize(902)
        let pid = fixture.pid
        await #expect(throws: OCRRuntimeFailure.timedOut) {
            try await fixture.recognize(400, purpose: .reading, deadline: ProcessInfo.processInfo.systemUptime - 1)
        }
        _ = try await fixture.recognize(902)
        #expect(fixture.requests == [902, 902])
        #expect(fixture.pid == pid && fixture.events.count("retired") == 0)
    }
    @Test func stalledWorkerTimesOutIsReapedAndNextRequestRecovers() async throws {
        let fixture = try OCRRuntimeFixture()
        defer { fixture.close() }
        do {
            _ = try await fixture.recognize(901)
            Issue.record("A nonresponding worker returned a result")
        } catch let failure as OCRRuntimeFailure { #expect(failure == .timedOut) }
        let oldPID = try #require(fixture.pid)
        try await waitUntil { fixture.events.count("retired") == 1 }
        #expect(fixture.runtime.processID == nil)
        #expect(kill(oldPID, 0) == -1, "The SIGTERM-ignoring worker must be killed before another is admitted")
        let result = try await fixture.recognize(902)
        #expect(result.lines.first?.text == "902")
        #expect(fixture.pid != oldPID)
        #expect(fixture.runtime.processID == fixture.pid)
    }

    @Test func logicalCancellationFinishesCallerButRetainsNativeSlot() async throws {
        let fixture = try OCRRuntimeFixture()
        defer { fixture.close() }
        let task = Task { try await fixture.recognize(903) }
        try await waitUntil { fixture.requests == [903] }
        let pid = try #require(fixture.pid)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled caller received text") } catch is CancellationError {}
        #expect(kill(pid, 0) == 0, "Ordinary cancellation must not call native cancel or kill the active worker")
        // Shared Dispatch and MainActor remain usable while the child waits indefinitely.
        let canary = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: true) }
        }
        #expect(canary)
        try fixture.release()
        try await waitUntil { fixture.events.count("finished") == 1 }
        let next = try await fixture.recognize(902)
        #expect(next.lines.first?.text == "902" && fixture.pid == pid)
    }

    @Test func requestStormKeepsTwoPendingImagesAndPrioritizesExplicitReading() async throws {
        let fixture = try OCRRuntimeFixture(timeout: 5)
        defer { fixture.close() }
        let active = Task { try await fixture.recognize(903) }
        try await waitUntil { fixture.requests == [903] }
        let superseded = (1...100).map { marker in Task { try await fixture.recognize(marker) } }
        try await waitUntil { fixture.events.count("queued") == 101 }
        let reading = Task { try await fixture.recognize(400, purpose: .reading) }
        let latest = Task { try await fixture.recognize(401) }
        try await waitUntil { fixture.events.count("queued") == 103 }
        #expect(fixture.events.maximumPending <= 2)
        try fixture.release()
        _ = try await active.value
        #expect(try await reading.value.lines.first?.text == "400")
        #expect(try await latest.value.lines.first?.text == "401")
        for task in superseded {
            do { _ = try await task.value; Issue.record("Superseded queued request was executed") } catch is CancellationError {}
        }
        #expect(fixture.requests == [903, 400, 401])
    }

    @Test func cancellingQueuedWorkRemovesItWithoutTouchingTheActiveOperation() async throws {
        let fixture = try OCRRuntimeFixture(timeout: 5)
        defer { fixture.close() }
        let active = Task { try await fixture.recognize(903) }
        try await waitUntil { fixture.requests == [903] }
        let pending = Task { try await fixture.recognize(402, purpose: .reading) }
        try await waitUntil { fixture.events.count("queued") == 2 }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Queued cancellation was ignored") } catch is CancellationError {}
        try fixture.release()
        _ = try await active.value
        let barrier = try await fixture.recognize(902)
        #expect(barrier.lines.first?.text == "902")
        #expect(fixture.requests == [903, 902])
    }

    @Test(arguments: [904, 905, 906])
    func malformedResponseOrWorkerCrashDoesNotPoisonTheNextSession(marker: Int) async throws {
        let fixture = try OCRRuntimeFixture()
        defer { fixture.close() }
        do { _ = try await fixture.recognize(marker); Issue.record("Broken response was accepted") }
        catch let failure as OCRRuntimeFailure {
            #expect(failure == .invalidResponse || failure == .workerExited)
        }
        try await waitUntil { fixture.events.count("retired") == 1 }
        #expect(try await fixture.recognize(902).lines.first?.text == "902")
    }

    @Test func repeatedFailuresBackOffAndAHealthyResultResetsTheFailureCount() async throws {
        let fixture = try OCRRuntimeFixture(timeout: 0.5, cooldown: 0.3)
        defer { fixture.close() }
        for number in 1...3 {
            do { _ = try await fixture.recognize(901); Issue.record("Stalled worker succeeded") }
            catch let failure as OCRRuntimeFailure { #expect(failure == .timedOut) }
            try await waitUntil { fixture.events.count("retired") == number }
        }
        let pid = fixture.pid
        do { _ = try await fixture.recognize(902); Issue.record("Cooldown was ignored") }
        catch let failure as OCRRuntimeFailure { #expect(failure == .unavailable) }
        #expect(fixture.pid == pid, "Backoff must not launch another worker")
        try await Task.sleep(for: .milliseconds(350))
        _ = try await fixture.recognize(902)
        do { _ = try await fixture.recognize(901) } catch {}
        try await waitUntil { fixture.events.count("retired") == 4 }
        #expect(fixture.events.lastBackoff == "0.0")
    }

    @Test func shutdownCancelsActiveAndPendingAndRejectsNewWork() async throws {
        let fixture = try OCRRuntimeFixture(timeout: 5)
        defer { fixture.close() }
        let active = Task { try await fixture.recognize(903) }
        try await waitUntil { fixture.requests == [903] }
        let pid = try #require(fixture.pid)
        let pending = Task { try await fixture.recognize(902) }
        try await waitUntil { fixture.events.count("queued") == 2 }
        fixture.runtime.shutdown()
        for task in [active, pending] {
            do { _ = try await task.value; Issue.record("Shutdown delivered a result") } catch is CancellationError {}
        }
        // Kernel exit can precede Process's reaping callback by one transport poll.
        try await waitUntil { kill(pid, 0) == -1 && fixture.runtime.processID == nil }
        #expect(fixture.runtime.processID == nil)
        do { _ = try await fixture.recognize(902); Issue.record("Closed runtime admitted work") }
        catch let failure as OCRRuntimeFailure { #expect(failure == .shuttingDown) }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), "OCR runtime did not reach the expected state")
    }

    @Test(arguments: [8, 16, 32])
    func transportedPixelsMatchThePreviousRGBAConversion(maximumDimension: Int) async throws {
        let fixture = try OCRRuntimeFixture()
        defer { fixture.close() }
        let source = try #require(CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.5, alpha: 0.6))
        source.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        source.setFillColor(CGColor(red: 0, green: 1, blue: 0.1, alpha: 1))
        source.fill(CGRect(x: 3, y: 2, width: 12, height: 7))
        let image = try #require(source.makeImage())
        let scale = min(1, Double(maximumDimension) / 32)
        let width = Int(32 * scale), height = Int(18 * scale)
        let previous = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        previous.interpolationQuality = .medium
        previous.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(previous.data)
        let expected = SHA256.hash(data: Data(bytes: bytes, count: width * height * 4))
            .map { String(format: "%02x", $0) }.joined()
        let result = try await fixture.runtime.recognize(image, options:
            .init(maxImageDimension: maximumDimension, maxRecognizedCharacters: 907))
        #expect(result.lines.first?.text == expected)
    }

    @Test func cancellationBeforeTheFirstHeaderKeepsThePipeReusable() async throws {
        let fixture = try OCRRuntimeFixture()
        defer { fixture.close() }
        let result = try await Self.cancelBeforeSending(helper: fixture.directory.appendingPathComponent("worker.py"), image: fixture.image)
        #expect(result.lines.first?.text == "902")
        #expect(fixture.requests == [902])
    }

    @concurrent
    private nonisolated static func cancelBeforeSending(helper: URL, image: CGImage) async throws -> OCRWorkerResponse {
        let worker = OCRWorkerProcess(executable: helper)
        defer { worker.stop() }
        let options = OCRRequestOptions(maxImageDimension: 16, maxRecognizedCharacters: 902)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        do {
            _ = try worker.recognize(image: image, options: options, id: "skip-without-launch", deadline: deadline,
                isShuttingDown: { false }, isCancelled: { true })
            Issue.record("Cancelled preparation launched recognition")
        } catch is CancellationError {}
        #expect(worker.identifier == nil)
        var checks = 0
        do {
            _ = try worker.recognize(image: image, options: options, id: "skip-after-start", deadline: deadline,
                isShuttingDown: { false }, isCancelled: { checks += 1; return checks == 2 })
            Issue.record("Cancelled startup sent an image frame")
        } catch is CancellationError {}
        #expect(worker.identifier != nil)
        return try worker.recognize(image: image, options: options, id: "healthy-next-frame", deadline: deadline,
                                    isShuttingDown: { false })
    }
}

/// Test-only helper modes use normal framed input and output. The script is never bundled into
/// either app target; its PID and request log let tests assert real retirement and queue bounds.
@MainActor
final class OCRRuntimeFixture {
    let directory: URL
    let runtime: OCRRuntime
    let events = OCRRuntimeEvents()
    let image: CGImage

    init(timeout: TimeInterval = 5, cooldown: TimeInterval = 0.3) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OCRRuntime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("worker.py")
        try Self.script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var configuration = OCRRuntime.Configuration()
        configuration.contextTimeout = timeout
        configuration.readingTimeout = timeout
        configuration.retryDelay = 0
        configuration.cooldown = cooldown
        configuration.idleTimeout = 5
        let events = events
        runtime = OCRRuntime(helperURL: helper, configuration: configuration, events: { _, metadata in events.record(metadata) })
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image = try #require(context.makeImage())
    }

    var pid: Int32? {
        (try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var requests: [Int] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { Int($0) }
    }

    func recognize(_ marker: Int, purpose: OCRRequestPurpose = .visualContext,
                   deadline: TimeInterval? = nil) async throws -> OCRWorkerResponse {
        let options = OCRRequestOptions(maxImageDimension: 16, maxRecognizedCharacters: marker, purpose: purpose, deadline: deadline)
        return try await runtime.recognize(image, options: options)
    }

    func release() throws { try Data().write(to: directory.appendingPathComponent("release")) }
    func close() { runtime.shutdown(); try? FileManager.default.removeItem(at: directory) }

    private static let script = #"""
#!/usr/bin/python3
import hashlib, json, os, signal, struct, sys, time
from pathlib import Path
root = Path(__file__).parent
(root / 'pid').write_text(str(os.getpid()))
def read(n):
    data = b''
    while len(data) < n:
        part = sys.stdin.buffer.read(n - len(data))
        if not part: sys.exit(0)
        data += part
    return data
while True:
    count = struct.unpack('>I', read(4))[0]
    request = json.loads(read(count))
    marker = request['maximumCharacters']
    if marker == 905: os._exit(7)
    pixels = read(request['width'] * request['height'] * 4)
    with (root / 'requests').open('a') as log: log.write(str(marker) + '\n')
    if marker == 901:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(0.1)
    if marker == 903:
        while not (root / 'release').exists(): time.sleep(0.01)
    if marker == 904:
        sys.stdout.buffer.write(struct.pack('>I', 8388609)); sys.stdout.buffer.flush()
        continue
    result = {'version': 1, 'id': 'stale-id' if marker == 906 else request['id'],
              'lines': [{'text': hashlib.sha256(pixels).hexdigest() if marker == 907 else str(marker),
                         'confidence': 1, 'boundingBox': [[0,0],[1,1]]}], 'words': []}
    data = json.dumps(result).encode()
    sys.stdout.buffer.write(struct.pack('>I', len(data)) + data)
    sys.stdout.buffer.flush()
"""#
}

/// Runtime events cross the transport thread; this lock stores only content-free test evidence.
nonisolated final class OCRRuntimeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: String]] = []
    func record(_ event: [String: String]) { lock.withLock { entries.append(event) } }
    func count(_ phase: String) -> Int { lock.withLock { entries.filter { $0["phase"] == phase }.count } }
    var maximumPending: Int { lock.withLock { entries.compactMap { $0["pending_count"].flatMap(Int.init) }.max() ?? 0 } }
    var lastBackoff: String? { lock.withLock { entries.last { $0["phase"] == "retired" }?["backoff_seconds"] } }
}
