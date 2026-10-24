import Darwin
import Foundation

/// A child process exposes cumulative CPU time and physical footprint without granting the app
/// task-port access. The Performance store samples only PIDs supplied by its own runtime graph.
nonisolated struct OwnedProcessResourceReading: Equatable {
    let cpuNanoseconds: UInt64
    let footprintBytes: UInt64
    let startTime: UInt64
}

nonisolated enum OwnedProcessResourceReader {
    static func read(pid: pid_t) -> OwnedProcessResourceReading? {
        var identity = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, size) == size,
              identity.pbi_ppid == UInt32(getpid()) else { return nil }
        var usage = rusage_info_v4()
        // libproc's void-pointer ABI is isolated here; the buffer has the exact V4 struct size.
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return .init(cpuNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
            footprintBytes: usage.ri_phys_footprint, startTime: usage.ri_proc_start_abstime)
    }

    static func cpuPercent(previous: OwnedProcessResourceReading?, current: OwnedProcessResourceReading,
                           elapsed: TimeInterval) -> Double {
        guard let previous, previous.startTime == current.startTime,
              current.cpuNanoseconds >= previous.cpuNanoseconds, elapsed > 0 else { return 0 }
        return Double(current.cpuNanoseconds - previous.cpuNanoseconds) / 1_000_000_000 / elapsed * 100
    }
}
