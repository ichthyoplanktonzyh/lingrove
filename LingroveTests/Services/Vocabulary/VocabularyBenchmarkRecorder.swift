import Foundation
import Testing

/// One suite owns this recorder. It writes only labels, fixture counts and monotonic durations;
/// report IO and correctness assertions run after the measured closure has returned. A result
/// must be consumed by its caller so Release optimization cannot remove the measured work.
@MainActor
final class VocabularyBenchmarkRecorder {
    struct Sample: Encodable {
        let operation: String
        let layer: String
        let entries: Int
        let trial: Int
        let visibleEntriesBefore: Int?
        let visibleEntriesAfter: Int?
        let milliseconds: Double
    }
    let entries: Int
    let trial: Int
    var visibleEntries: (() -> Int)?
    private let output: URL

    init(entries: Int, trial: Int, output: URL) {
        self.entries = entries; self.trial = trial; self.output = output
    }

    func measure<T>(_ operation: String, layer: String = "store",
                    _ body: () async throws -> T) async throws -> T {
        let countBefore = visibleEntries?()
        let start = ContinuousClock.now
        let result = try await body()
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        let sample = Sample(operation: operation, layer: layer, entries: entries, trial: trial,
            visibleEntriesBefore: countBefore, visibleEntriesAfter: visibleEntries?(), milliseconds: milliseconds)
        let file = output.appendingPathComponent("samples.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(sample) + Data([10]))
        print("CORPUS_BENCHMARK \(entries) trial=\(trial) \(operation) \(String(format: "%.3f", milliseconds))ms")
        return result
    }

    /// An observed rejection is evidence, not a successful latency sample. Keeping outcomes
    /// separate lets the report exclude it without abandoning unrelated inventory operations.
    func outcome(_ operation: String, succeeded: Bool, message: String?) throws {
        let data: [String: Any] = ["operation": operation, "entries": entries, "trial": trial,
            "succeeded": succeeded, "message": message ?? ""]
        let file = output.appendingPathComponent("outcomes.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: data) + Data([10]))
    }
}
