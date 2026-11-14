import CryptoKit
import Foundation
import Testing
@testable import LingroveNotebookEngine

/// Opt-in qualification copies a previously exported synthetic seed into a private directory.
/// Preparation and subsequent queries are separate windows; the source is never opened by an engine.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LINGROVE_SEARCH_BENCHMARK_SEED"] != nil))
@MainActor struct NotebookSearchPerformanceTests {
    @Test func exportedSyntheticSearch() throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LINGROVE_SEARCH_BENCHMARK_SEED"]))
        let hash = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        for trial in 1...3 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-qualification-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("primary.sqlite")
            try FileManager.default.copyItem(at: source, to: url)
            let engine = try LingroveNotebookEngine(databaseURL: url, mediaDirectoryURL: root.appendingPathComponent("Media"))
            defer { try? engine.close() }
            func elapsed(_ start: ContinuousClock.Instant) -> Double {
                let duration = start.duration(to: .now).components
                return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            }
            var samples: [String: Double] = [:]
            var start = ContinuousClock.now
            let material = try engine.notebookLiteralSearchMaterial(locale: "en_US")
            samples["prepare_ms"] = elapsed(start)
            for query in ["word53", "word54", "word53 group-13", "shared", "cafe", "中文", "absent-needle"] {
                start = .now
                let result = try material.results(matching: query)
                samples[query] = elapsed(start)
                if query == "word53" { #expect(!result.entries.isEmpty) }
            }
            let record: [String: Any] = ["trial": trial, "seedSHA256": hash, "samples": samples]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("LINGROVE_SEARCH_BENCHMARK " + String(decoding: data, as: UTF8.self))
        }
    }
}
