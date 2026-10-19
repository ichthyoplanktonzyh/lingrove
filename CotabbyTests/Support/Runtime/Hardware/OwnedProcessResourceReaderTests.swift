import Testing
@testable import Cotabby

@Suite struct OwnedProcessResourceReaderTests {
    @Test func cpuUsesMonotonicDeltasAndAllowsSeveralBusyCores() {
        let previous = OwnedProcessResourceReading(cpuNanoseconds: 1_000_000_000, footprintBytes: 10, startTime: 1)
        let current = OwnedProcessResourceReading(cpuNanoseconds: 5_000_000_000, footprintBytes: 20, startTime: 1)
        #expect(OwnedProcessResourceReader.cpuPercent(previous: previous, current: current, elapsed: 2) == 200)
        #expect(OwnedProcessResourceReader.cpuPercent(previous: nil, current: current, elapsed: 2) == 0)
        #expect(OwnedProcessResourceReader.cpuPercent(previous: current, current: previous, elapsed: 2) == 0)
        let reusedPID = OwnedProcessResourceReading(cpuNanoseconds: 8_000_000_000, footprintBytes: 20, startTime: 2)
        #expect(OwnedProcessResourceReader.cpuPercent(previous: previous, current: reusedPID, elapsed: 2) == 0)
    }
}
