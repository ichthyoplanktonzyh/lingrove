import Foundation
import Testing
@testable import Lingrove

@MainActor
struct ScreenCaptureReplyTests {
    @Test func timeoutFinishesWithoutTheSDKCallbackAndDiscardsItsLateReply() async throws {
        var late: (@Sendable (Result<Int, Error>) -> Void)?
        let reply = ScreenCaptureReply<Int>()
        await #expect(throws: OCRRuntimeFailure.timedOut) {
            try await reply.wait(deadline: ProcessInfo.processInfo.systemUptime + 0.02) { late = $0 }
        }
        let callback = try #require(late)
        callback(.success(1)); callback(.failure(OCRRuntimeFailure.unavailable))
    }

    @Test func cancellationAlsoFinishesWithoutACallback() async throws {
        var late: (@Sendable (Result<Int, Error>) -> Void)?
        let task = Task {
            try await ScreenCaptureReply<Int>().wait(deadline: ProcessInfo.processInfo.systemUptime + 10) { late = $0 }
        }
        for _ in 0..<100 where late == nil { await Task.yield() }
        let callback = try #require(late)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        callback(.success(2))
    }

    @Test func anAlreadyExpiredCaptureDoesNotStartTheSDK() async {
        var started = false
        await #expect(throws: OCRRuntimeFailure.timedOut) {
            try await ScreenCaptureReply<Int>().wait(deadline: ProcessInfo.processInfo.systemUptime - 1) { _ in started = true }
        }
        #expect(!started)
    }

    @Test func callbackValueWinsOnceAndCancelsTheWatchdog() async throws {
        let value = try await ScreenCaptureReply<Int>().wait(deadline: ProcessInfo.processInfo.systemUptime + 1) {
            $0(.success(42)); $0(.success(99))
        }
        #expect(value == 42)
    }
}
