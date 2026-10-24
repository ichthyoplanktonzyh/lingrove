import Foundation
import Testing
@testable import Lingrove

/// Speech and OCR share one sampling cadence. Script helper exit/restart (including PID reuse)
/// to ensure adding the OCR owner cannot double count memory or invent CPU/GPU spikes.
@MainActor
struct SystemMetricsOwnershipTests {
    @Test func multipleHelpersAreDeduplicatedAndTheirCounterEpochsAreIndependent() async throws {
        var phase = 0
        var childReads = 0
        let store = SystemMetricsStore(sampleInterval: 0.01, sampler: {
            phase += 1
            return .init(cpuPercent: 5, footprintBytes: 100)
        }, gpuSampler: {
            .init(deviceUtilizationPercent: nil, inUseMemoryBytes: nil,
                  processGPUTimeNanoseconds: UInt64(phase) * 1_000_000_000)
        }, uptime: { Double(phase) })
        store.ownedProcessIDs = { phase == 3 ? [43, 99] : [getpid(), 42, 43, 42, 99] }
        store.ownedProcessSampler = { pid in
            #expect(pid != getpid())
            childReads += 1
            if pid == 99 { return nil }
            let start: UInt64 = pid == 42 && phase >= 4 ? UInt64(phase - 2) : 1
            return .init(cpuNanoseconds: UInt64(phase) * (pid == 42 ? 1 : 2) * 1_000_000_000,
                         footprintBytes: pid == 42 ? (phase >= 4 ? 4_000 : 1_000) : 2_000, startTime: start)
        }
        store.beginSampling()
        defer { store.endSampling() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.samples.count < 5 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(store.samples.count >= 5)
        let samples = Array(store.samples.prefix(5))
        #expect(samples.map(\.footprintBytes) == [3_100, 3_100, 2_100, 6_100, 6_100])
        #expect(samples.map(\.cpuPercent) == [5, 305, 205, 205, 205])
        #expect(samples.map(\.gpuPercent) == [nil, 100, nil, nil, nil])
        #expect(childReads == phase * 3 - 1)
    }
}
