import CoreGraphics
import Foundation
import Testing
@testable import Lingrove

/// Exercises the production worker's queue boundary without installing global taps or injecting
/// keys into the user's apps. Holding the main actor unavailable is the regression trigger: an
/// ordinary key must return on the input queue before any main-actor observer can execute.
@MainActor
struct InputEventTapWorkerTests {
    @Test func ordinaryTypingAndSyntheticKeysReturnWhileMainActorIsUnavailable() async {
        var observations: [InputMonitorKeyEvent] = []
        var confirmations = 0
        let routing = InputEventTapRouting(isMonitoring: true,
            decisionBindings: [InputKeyBinding(48), InputKeyBinding(17, [.control, .option])])
        let worker = InputEventTapWorker(routing: routing) { delivery, mayConsume in
            if case let .key(event, _) = delivery { observations.append(event) }
            if mayConsume { confirmations += 1 }
            return true
        }
        defer { worker.stop() }
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue(label: "LingroveTests.ordinary-input").async {
            for _ in 0..<32 {
                _ = worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 0, characters: "a"), isSynthetic: false))
                _ = worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 0, characters: "中文🙂"), isSynthetic: false))
                // Even a synthetic event whose key code matches Accept Word cannot wait for it.
                _ = worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 48), isSynthetic: true))
            }
            returned.signal()
        }
        // This synchronous wait intentionally holds the main actor. A main-queue sync on the
        // ordinary path times out here; it cannot accidentally pass by executing the observers.
        #expect(holdMainActor(until: returned, timeout: .now() + 1) == .success)
        #expect(observations.isEmpty)
        await drainMainQueue()
        #expect(observations.count == 96)
        #expect(observations.dropFirst().first?.characters == "中文🙂")
        #expect(confirmations == 0)
    }

    @Test func candidateWaitsForObservationAndReturnsTheConfirmedDecision() async {
        for consumes in [false, true] {
            var sequence: [CGKeyCode] = []
            var confirmationSequence: [CGKeyCode] = []
            let worker = InputEventTapWorker(routing: InputEventTapRouting(isMonitoring: true,
                decisionBindings: [InputKeyBinding(48)])) { delivery, mayConsume in
                if case let .key(event, _) = delivery {
                    sequence.append(event.keyCode)
                    if mayConsume { confirmationSequence.append(event.keyCode) }
                }
                return consumes
            }
            let result = await withCheckedContinuation { continuation in
                DispatchQueue(label: "LingroveTests.ordered-input").async {
                    _ = worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 0, characters: "a"), isSynthetic: false))
                    continuation.resume(returning: worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 48), isSynthetic: false)))
                }
            }
            #expect(result == consumes)
            #expect(sequence == [0, 48])
            #expect(confirmationSequence == [48])
            worker.stop()
        }
    }

    @Test func stoppedWorkerDiscardsQueuedObservationsAndFailsOpen() async {
        var deliveries = 0
        let worker = InputEventTapWorker(routing: InputEventTapRouting(isMonitoring: true)) { _, _ in
            deliveries += 1
            return true
        }
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue(label: "LingroveTests.stop-input").async {
            _ = worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 0, characters: "a"), isSynthetic: false))
            returned.signal()
        }
        #expect(holdMainActor(until: returned, timeout: .now() + 1) == .success)
        worker.stop()
        await drainMainQueue()
        #expect(deliveries == 0)
        #expect(!worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 48), isSynthetic: false)))
    }

    @Test func routingUpdateUsesNewModifiersAndModalOwnership() async {
        var confirmed: [CGKeyCode] = []
        let worker = InputEventTapWorker(routing: InputEventTapRouting(isMonitoring: true,
            decisionBindings: [InputKeyBinding(48)])) { delivery, mayConsume in
            if mayConsume, case let .key(event, _) = delivery { confirmed.append(event.keyCode) }
            return mayConsume
        }
        defer { worker.stop() }
        worker.updateRouting(InputEventTapRouting(isMonitoring: true,
            decisionBindings: [InputKeyBinding(48, .shift)]))
        #expect(!(await send(worker, InputMonitorKeyEvent(keyCode: 48))))
        #expect(await send(worker, InputMonitorKeyEvent(keyCode: 48, flags: [.maskShift, .maskAlphaShift])))
        worker.updateRouting(InputEventTapRouting(isMonitoring: true, isModalCapture: true))
        #expect(await send(worker, InputMonitorKeyEvent(keyCode: 0, characters: "a")))
        worker.updateRouting(InputEventTapRouting(isMonitoring: true))
        #expect(!(await send(worker, InputMonitorKeyEvent(keyCode: 0, characters: "a"))))
        await drainMainQueue()
        #expect(confirmed == [48, 0])
    }

    @Test func reportsControlledDispatchComparisonUnderAThreeHundredMillisecondMainActorStall() async throws {
        var previousBridgeMilliseconds = 0.0
        var dispatchMilliseconds: [Double] = []
        let previousEntered = DispatchSemaphore(value: 0)
        let previousReturned = DispatchSemaphore(value: 0)
        let newReturned = DispatchSemaphore(value: 0)
        let worker = InputEventTapWorker(routing: InputEventTapRouting(isMonitoring: true,
            decisionBindings: [InputKeyBinding(48)])) { _, _ in false }
        defer { worker.stop() }
        DispatchQueue(label: "LingroveTests.previous-main-thread-tap").async {
            let began = DispatchTime.now().uptimeNanoseconds
            previousEntered.signal()
            // This models the previous default tap's scheduling dependency, not native Quartz
            // transport or actual keystroke-to-screen latency in a host application.
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    previousBridgeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                }
            }
            previousReturned.signal()
        }
        #expect(holdMainActor(until: previousEntered, timeout: .now() + 1) == .success)
        DispatchQueue(label: "LingroveTests.new-input-thread-tap").async {
            var samples: [Double] = []
            for _ in 0..<256 {
                let began = DispatchTime.now().uptimeNanoseconds
                _ = worker.dispatch(.key(InputMonitorKeyEvent(keyCode: 0, characters: "a"), isSynthetic: false))
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            }
            let collected = samples
            DispatchQueue.main.async { MainActor.assumeIsolated { dispatchMilliseconds = collected } }
            newReturned.signal()
        }
        // The main actor is deliberately unavailable for both paths during this entire wait.
        _ = holdMainActor(until: DispatchSemaphore(value: 0), timeout: .now() + .milliseconds(300))
        #expect(holdMainActor(until: newReturned, timeout: .now() + 1) == .success)
        await drainMainQueue()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { previousReturned.wait(); continuation.resume() }
        }
        let sorted = dispatchMilliseconds.sorted()
        try #require(sorted.count == 256)
        let report: [String: Any] = ["experiment": "controlled_callback_dispatch", "native_quartz_latency": false,
            "main_actor_stall_ms": 300, "samples": sorted.count,
            "previous_main_thread_bridge_ms": previousBridgeMilliseconds,
            "new_dispatch_p50_ms": sorted[127], "new_dispatch_p95_ms": sorted[242],
            "new_dispatch_p99_ms": sorted[252], "new_dispatch_max_ms": sorted[255]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let reportText = try #require(String(data: data, encoding: .utf8))
        print("INPUT_DISPATCH_PROBE " + reportText)
        if let directory = ProcessInfo.processInfo.environment["LINGROVE_INPUT_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("dispatch-probe.json"))
        }
    }

    /// The synchronous helper deliberately holds MainActor for this regression experiment. Using
    /// an asynchronous wait would let its observers run, hiding the exact scheduling bug we test.
    private func holdMainActor(until semaphore: DispatchSemaphore, timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }

    private func send(_ worker: InputEventTapWorker, _ event: InputMonitorKeyEvent) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: worker.dispatch(.key(event, isSynthetic: false)))
            }
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
