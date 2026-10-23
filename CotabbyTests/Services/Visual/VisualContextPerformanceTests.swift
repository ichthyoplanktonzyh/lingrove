import AppKit
import CryptoKit
import Darwin
import Testing
@testable import Cotabby

/// Local opt-in Release measurement: identical synthetic pixels and real Vision, with either the
/// previous unlimited refresh policy or the ten-second activity window. No model, AX or screen
/// permission is involved. Run this suite alone, after builds finish, to avoid measuring compiler
/// contention. Reports contain only timings, counters and hashes of synthetic excerpt text.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["RUN_OCR_PERFORMANCE"] == "1"))
struct VisualContextPerformanceTests {
    @Test func compareIdleRefreshPoliciesWithRealVision() async throws {
        let image = try makeImage()
        let before = try await measure(image: image, idleInterval: .infinity, observeRelease: false)
        let after = try await measure(image: image, idleInterval: 10, observeRelease: true)
        let report = ["continuous_refresh": before, "activity_gated_refresh": after]
        let encoded = try JSONEncoder().encode(report)
        if let path = ProcessInfo.processInfo.environment["OCR_PERFORMANCE_REPORT"] {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("OCR idle comparison: \(before.requests) -> \(after.requests) requests; " +
              "CPU seconds \(before.cpuSeconds) -> \(after.cpuSeconds)")
        #expect(after.requests < before.requests / 2)
        #expect(before.failures == 0 && after.failures == 0)
        #expect(!before.excerptHashes.isEmpty && before.excerptHashes == after.excerptHashes)
        #expect(after.helperReleased)
    }

    private func measure(image: CGImage, idleInterval: TimeInterval, observeRelease: Bool) async throws -> OCRIdleMeasurement {
        let events = OCRBenchmarkEvents()
        let runtime = OCRRuntime(events: { _, metadata in events.record(metadata) })
        let capture = OCRBenchmarkCapture(image: image)
        let generator = ScreenshotContextGenerator(ocrRuntime: runtime, screenshotService: capture)
        let coordinator = VisualContextCoordinator(screenshotContextGenerator: generator,
            screenRecordingPermissionProvider: { true }, idleInterval: idleInterval)
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(applicationName: "Synthetic performance fixture",
            inputFrameRect: nil, precedingText: "My draft")
        coordinator.refreshContextProvider = { snapshot }
        var excerpts: Set<String> = []
        coordinator.onStateChange = { status, text in
            if status == .ready, let text {
                excerpts.insert(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
            }
        }
        defer { coordinator.cancel(resetState: true); runtime.shutdown() }
        var childCPU: [UInt64: UInt64] = [:]
        var peakFootprint: UInt64 = 0
        func sample() {
            var footprint = SystemResourceSampler.sample().footprintBytes
            if let pid = runtime.processID, let child = OwnedProcessResourceReader.read(pid: pid) {
                childCPU[child.startTime] = max(childCPU[child.startTime] ?? 0, child.cpuNanoseconds)
                footprint += child.footprintBytes
            }
            peakFootprint = max(peakFootprint, footprint)
        }
        let cpuStarted = processCPUSeconds()
        let started = ProcessInfo.processInfo.systemUptime
        coordinator.startSessionIfNeeded(for: snapshot, configuration: .local)
        repeat {
            try await Task.sleep(for: .seconds(1))
            sample()
        } while ProcessInfo.processInfo.systemUptime - started < 60
        coordinator.cancel(resetState: true)
        let drainDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while events.inFlight > 0 && ContinuousClock.now < drainDeadline { try await Task.sleep(for: .milliseconds(10)) }
        sample()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let cpu = processCPUSeconds() - cpuStarted + Double(childCPU.values.reduce(0, +)) / 1_000_000_000
        let latencies = events.latencies.sorted()
        if observeRelease {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while runtime.processID != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
        let helperReleased = runtime.processID == nil
        runtime.shutdown()
        let shutdownDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while runtime.processID != nil && ContinuousClock.now < shutdownDeadline { try await Task.sleep(for: .milliseconds(10)) }
        return .init(requests: capture.count, failures: events.failures, cpuSeconds: cpu, elapsedSeconds: elapsed,
            peakFootprintBytes: peakFootprint, medianLatencyMS: latencies.isEmpty ? 0 : latencies[latencies.count / 2],
            helperReleased: helperReleased, excerptHashes: excerpts.sorted())
    }

    private func makeImage() throws -> CGImage {
        let image = NSImage(size: NSSize(width: 1200, height: 600))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1200, height: 600)).fill()
        for index in 0..<8 {
            ("Project agenda \(index): review the budget and confirm the Friday deadline." as NSString).draw(
                at: NSPoint(x: 50, y: 80 + index * 55), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.black
                ])
        }
        image.unlockFocus()
        return try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

private struct OCRIdleMeasurement: Codable {
    let requests: Int
    let failures: Int
    let cpuSeconds: Double
    let elapsedSeconds: Double
    let peakFootprintBytes: UInt64
    let medianLatencyMS: Int
    let helperReleased: Bool
    let excerptHashes: [String]
}

/// A small changing square represents a caret/animation: byte-identical cache hits would otherwise
/// suppress OCR in both policies and hide the cost of refreshing a visually active, idle window.
@MainActor
private final class OCRBenchmarkCapture: WindowScreenshotCapturing {
    let image: CGImage
    private(set) var count = 0
    init(image: CGImage) { self.image = image }
    func captureSnapshot(around context: FocusedInputSnapshot, snapshotDimension: Int,
                         capturesEntireWindow: Bool) async throws -> CapturedWindowScreenshot {
        let bitmap = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        count += 1
        bitmap.setFillColor(CGColor(gray: Double(count % 256) / 255, alpha: 1))
        bitmap.fill(CGRect(x: 2, y: 2, width: 34, height: 34))
        return CapturedWindowScreenshot(image: try #require(bitmap.makeImage()), windowTitle: nil)
    }
}

/// Content-free runtime evidence from the native OCR thread, sampled by the benchmark MainActor.
private nonisolated final class OCRBenchmarkEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<String> = []
    private var durations: [Int] = []
    private var retired = 0
    var inFlight: Int { lock.withLock { active.count } }
    var latencies: [Int] { lock.withLock { durations } }
    var failures: Int { lock.withLock { retired } }
    func record(_ event: [String: String]) {
        lock.withLock {
            guard let id = event["request_id"] else { return }
            switch event["phase"] {
            case "started": active.insert(id)
            case "finished":
                active.remove(id)
                if let value = event["latency_ms"].flatMap(Int.init) { durations.append(value) }
            case "skipped": active.remove(id)
            case "retired": active.remove(id); retired += 1
            default: break
            }
        }
    }
}
