import CryptoKit
import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Optional measurements consume only the explicitly supplied closed synthetic exports.
/// One untimed additive-metadata/full-validation step qualifies a private clone's certificate;
/// canonical content and the original exported files remain unchanged.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LINGROVE_PROJECTION_SEEDS"] != nil))
@MainActor struct NotebookSearchProjectionScaleTests {
    @Test(arguments: [10_000, 20_000]) func projectionAtMacScale(_ count: Int) throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LINGROVE_PROJECTION_SEEDS"]))
        let source = directory.appendingPathComponent("\(count)/primary.sqlite")
        let seedHash = try hash(source)
        for trial in 1...3 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("projection-scale-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("primary.sqlite"), media = root.appendingPathComponent("Media")
            try FileManager.default.copyItem(at: source, to: url)
            var engine = try LingroveNotebookEngine(databaseURL: url, mediaDirectoryURL: media)
            let workspace = try #require(try engine.currentNotebookVersion()?.workspaceId)
            _ = try engine.loadLingroveNotebook(workspaceId: workspace)
            try engine.close(); engine = try LingroveNotebookEngine(databaseURL: url, mediaDirectoryURL: media)
            defer { try? engine.close() }
            func elapsed(_ start: ContinuousClock.Instant) -> Double {
                let duration = start.duration(to: .now).components
                return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            }
            var samples: [String: Double] = [:]
            var start = ContinuousClock.now
            let initial = try engine.prepareNotebookSearch(locale: "en_US")
            _ = try initial.results(matching: "word53")
            samples["uncached_search_including_persistence_ms"] = elapsed(start)
            #expect(initial.preparation == .canonical && engine.core.notebookSaveCache == nil)
            try engine.close(); engine = try LingroveNotebookEngine(databaseURL: url, mediaDirectoryURL: media)
            start = .now
            let hit = try engine.prepareNotebookSearch(locale: "en_US")
            _ = try hit.results(matching: "word54")
            samples["reopened_persisted_search_ms"] = elapsed(start)
            #expect(hit.preparation == .persisted && engine.core.notebookSaveCache == nil)
            let id = try #require(hit.headers.first?.id)
            let detail = try engine.notebookEntryDetail(entryID: id)
            var entry = try #require(detail.entry); entry.senses[0].note += " projection unique marker"
            start = .now
            _ = try engine.saveNotebookEntry(entry, basedOn: detail)
            samples["local_save_with_projection_delta_ms"] = elapsed(start)
            #expect(engine.core.notebookSaveCache == nil)
            start = .now
            let updated = try engine.prepareNotebookSearch(reusing: hit, locale: "en_US")
            #expect(try updated.results(matching: "projection unique marker").entries.map(\.id) == [id])
            samples["edited_search_and_compaction_ms"] = elapsed(start)
            #expect(updated.preparation == .incremental)
            let card = try #require(try engine.core.query(sql: "SELECT card_id FROM notebook_note_cards WHERE workspace_id=? ORDER BY card_id LIMIT 1",
                values: [.text(workspace)], map: { DatabaseCore.columnText(statement: $0, index: 0) }).first)
            start = .now
            let form = try engine.notebookNoteEditor(cardID: card, workspaceID: workspace)
            samples["cold_note_editor_read_ms"] = elapsed(start)
            start = .now
            _ = try engine.previewNotebookNote(form.model, basedOn: form)
            samples["note_editor_preview_ms"] = elapsed(start)
            #expect(try engine.core.notebookSaveCache == nil && engine.loadReviewEventCount() == 1_000)
            let record: [String: Any] = ["entries": count, "trial": trial, "seedSHA256": seedHash, "samples": samples]
            print("LINGROVE_PROJECTION_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
        }
        #expect(try self.hash(source) == seedHash)
    }

    private func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
