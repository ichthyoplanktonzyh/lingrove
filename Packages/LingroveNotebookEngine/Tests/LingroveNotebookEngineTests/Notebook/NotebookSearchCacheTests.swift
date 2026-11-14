import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

@MainActor struct NotebookSearchCacheTests {
    private func seed(_ f: NotebookMediaDatabaseFixture) throws -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<3).map { number in
            VocabularyEntry(id: UUID(), expression: "word\(number)", dictionaryForm: "lemma\(number)", language: .english,
                kind: .word, senses: [.init(id: UUID(), meaning: "Café 中文 \(number)", note: "original note", createdAt: now, updatedAt: now)],
                createdAt: now.addingTimeInterval(Double(number)), updatedAt: now)
        }
        let doc = VocabularyDocument(entries: entries)
        _ = try f.db.saveLingroveNotebook(doc, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        try f.reopen(); return doc
    }

    @Test func projectionSurvivesReopenAndNeverEstablishesWriterProof() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        _ = try seed(f)
        let before = try f.db.notebookChanges()
        let cold = try f.db.prepareNotebookSearch(locale: "en_US")
        #expect(cold.preparation == .canonical && f.db.core.notebookSaveCache == nil)
        #expect(try f.db.notebookChanges().stamp == before.stamp)
        try f.reopen()
        let hit = try f.db.prepareNotebookSearch(locale: "tr_TR")
        #expect(hit.preparation == .persisted && hit.locale == "tr_TR")
        #expect(try hit.results(matching: "cafe").entries == cold.results(matching: "cafe").entries)
        #expect(f.db.core.notebookSaveCache == nil)
        #expect(try f.db.prepareNotebookSearch(reusing: hit, locale: "en_US").preparation == .memory)
    }

    @Test func localEditsReplayAcrossConnectionsAndCompactAfterSearch() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = try seed(f)
        let before = try f.db.prepareNotebookSearch()
        for index in 0..<2 {
            let detail = try f.db.notebookEntryDetail(entryID: doc.entries[index].id)
            var entry = try #require(detail.entry); entry.senses[0].note = "updated marker \(index)"
            _ = try f.db.saveNotebookEntry(entry, basedOn: detail)
        }
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates", values: []) == 2)
        try f.reopen()
        let patched = try f.db.prepareNotebookSearch()
        #expect(patched.preparation == .incremental)
        let complete = try f.db.notebookLiteralSearchMaterial()
        for query in ["", "updated", "marker 0", "cafe", "中文", "original note", "lemma1"] {
            #expect(try patched.results(matching: query).entries == complete.results(matching: query).entries)
        }
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates", values: []) == 0)
        #expect(try f.db.prepareNotebookSearch().preparation == .persisted)
        #expect(try before.results(matching: "updated").entries.isEmpty)
    }

    @Test func rawSameRevisionWritesAndMissingDeltaChainsRebuild() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = try seed(f); let old = try f.db.prepareNotebookSearch()
        try f.db.core.execute(sql: "UPDATE notebook_collections SET payload_json=json_set(payload_json,'$.note','raw marker') WHERE workspace_id=? AND sense_id=?",
            values: [.text(f.workspace), .text(doc.entries[0].senses[0].id.uuidString)])
        let next = try f.db.prepareNotebookSearch(reusing: old)
        #expect(next.fence.version == old.fence.version && next.preparation == .canonical)
        #expect(try next.results(matching: "raw marker").entries.count == 1)
        let detail = try f.db.notebookEntryDetail(entryID: doc.entries[1].id)
        var entry = try #require(detail.entry); entry.senses[0].note = "gap marker"
        _ = try f.db.saveNotebookEntry(entry, basedOn: detail)
        try f.db.core.execute(sql: "DELETE FROM notebook_literal_search_updates", values: [])
        #expect(try f.db.prepareNotebookSearch().preparation == .canonical)
    }

    @Test func warmAndBatchWritersShareOneProjectionFrame() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = try seed(f); _ = try f.db.prepareNotebookSearch()
        var scope = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        var first = doc.entries[0]; first.senses[0].note = "warm update marker"
        scope = try f.db.saveNotebookEntry(first, basedOn: scope)
        let warm = try f.db.prepareNotebookSearch()
        #expect(warm.preparation == .incremental)
        #expect(try warm.results(matching: "warm update marker").entries.map(\.id) == [first.id])
        var batch = Array(doc.entries.suffix(2))
        for index in batch.indices { batch[index].senses[0].note = "batch update marker" }
        _ = try f.db.saveNotebookEntries(batch, basedOn: scope)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates", values: []) == 1)
        let updated = try f.db.prepareNotebookSearch(reusing: warm)
        #expect(updated.preparation == .incremental)
        #expect(Set(try updated.results(matching: "batch update marker").entries.map(\.id)) == Set(batch.map(\.id)))
        #expect(try updated.results(matching: "").entries == f.db.notebookLiteralSearchMaterial().results(matching: "").entries)
    }

    @Test func localDeletionRemovesOnlyItsCachedOwner() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = try seed(f); _ = try f.db.prepareNotebookSearch()
        let version = try #require(try f.db.currentNotebookVersion())
        let removed = try f.db.tryRemoveNotebookSense(doc.entries[0].senses[0].id, from: doc.entries[0].id, basedOn: version)
        #expect(removed != nil)
        let next = try f.db.prepareNotebookSearch()
        #expect(next.preparation == .incremental)
        #expect(try next.results(matching: "word0").entries.isEmpty)
        #expect(try next.results(matching: "").entries.count == 2)
        #expect(try next.results(matching: "").entries == f.db.notebookLiteralSearchMaterial().results(matching: "").entries)
    }

    @Test func corruptPayloadOrValidChecksumWithInvalidReferencesFallsBack() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        _ = try seed(f); _ = try f.db.prepareNotebookSearch()
        try f.db.core.execute(sql: "UPDATE notebook_literal_search_cache SET payload=?", values: [.blob(Data([0]))])
        #expect(try f.db.prepareNotebookSearch().preparation == .canonical)
        let valid = NotebookSearchProjection(try f.db.notebookLiteralSearchMaterial())
        let invalid = NotebookSearchProjection(fence: valid.fence, texts: [], headers: valid.headers, dates: valid.dates,
            fields: valid.fields, nodes: valid.nodes, mappings: valid.mappings, cues: valid.cues, patterns: valid.patterns)
        let damaged = try #require(NotebookSearchBinaryCodec.encode(invalid))
        try f.db.core.execute(sql: "UPDATE notebook_literal_search_cache SET payload=?,sha256=?",
            values: [.blob(damaged), .text(NotebookSearchCache.digest(damaged))])
        #expect(try f.db.prepareNotebookSearch().preparation == .canonical)
    }

    @Test func binaryCodecRejectsTruncationTrailingBytesAndOversizedCounts() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        _ = try seed(f)
        let material = try f.db.notebookLiteralSearchMaterial()
        let bytes = try #require(NotebookSearchBinaryCodec.encode(NotebookSearchProjection(material)))
        let decoded = try #require(NotebookSearchBinaryCodec.decode(bytes)?.material(fence: material.fence, locale: "en_US"))
        #expect(try decoded.results(matching: "cafe 中文").entries == material.results(matching: "cafe 中文").entries)
        for cut in 0..<bytes.count { #expect(NotebookSearchBinaryCodec.decode(bytes.prefix(cut)) == nil) }
        #expect(NotebookSearchBinaryCodec.decode(bytes + Data([0])) == nil)
        var malformed = bytes
        malformed.replaceSubrange(4..<8, with: [255,255,255,255])
        #expect(NotebookSearchBinaryCodec.decode(malformed) == nil)
    }

    @Test func lateDeltaFailureRollsBackCanonicalRowsAndCheckpoint() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = try seed(f)
        try f.db.core.executeScript(sql: """
            CREATE TRIGGER reject_search_delta BEFORE INSERT ON notebook_literal_search_updates
            BEGIN SELECT RAISE(ABORT,'Synthetic late delta failure'); END;
            """, errorContext: "Protect search delta atomicity")
        _ = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        try f.reopen(); _ = try f.db.prepareNotebookSearch()
        let detail = try f.db.notebookEntryDetail(entryID: doc.entries[0].id)
        var entry = try #require(detail.entry); entry.senses[0].note = "must roll back"
        #expect(throws: (any Error).self) { try f.db.saveNotebookEntry(entry, basedOn: detail) }
        #expect(try f.db.notebookEntryDetail(entryID: entry.id).entry == detail.entry)
        #expect(try f.db.notebookBrowseFence() == detail.fence)
        #expect(try f.db.prepareNotebookSearch().preparation == .persisted)
    }

    @Test func deletionCascadesCacheAndCancellationDoesNotPublish() async throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        _ = try seed(f)
        let task = Task { try f.db.prepareNotebookSearch() }; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_cache", values: []) == 0)
        _ = try f.db.prepareNotebookSearch()
        try f.db.core.execute(sql: "DELETE FROM notebook_state WHERE workspace_id=?", values: [.text(f.workspace)])
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_cache", values: []) == 0)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates", values: []) == 0)
    }
}
