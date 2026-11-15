import Foundation
import LingroveNotebook
import LingroveNotebookSync
import Testing
@testable import LingroveNotebookEngine

/// Annotation proofs retain owners and history. These private SQLite fixtures also distinguish
/// tag occurrences from equal search words and protect cache-version/replay boundaries.
@MainActor struct NotebookTagOptimizationTests {
    private func document(_ count: Int = 120) -> VocabularyDocument {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<count).map { index in
            VocabularyEntry(id: UUID(), expression: "word\(index)", dictionaryForm: index == 2 ? "tagneedle" : "word\(index)",
                language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: index == 0 ? "tagneedle" : "definition \(index)",
                    note: index == 1 ? "tagneedle" : "", tags: ["tagneedle", "keep", "Café"],
                    examples: index == 3 ? [.init(id: UUID(), text: "tagneedle", translation: "context", ranges: [],
                        completeness: .sentence, meaning: "", createdAt: date)] : [], createdAt: date, updatedAt: date)],
                createdAt: date.addingTimeInterval(Double(index)), updatedAt: date)
        }
        return .init(entries: entries)
    }

    @Test func tagProofRetainsOwnersAndItsPublicScopeMatchesTheWire() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(document(4), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let cached = try #require(f.db.core.notebookSaveCache)
        let change = try cached.state.removingTag("tagneedle", now: Date(timeIntervalSince1970: 1_700_001_000))
        #expect(VocabularyWirePublicIntent.hasChanges(change))
        #expect(try VocabularyWirePublicIntent.hasChanges(from: saved.document, to: change.state.document, notebookID: saved.notebookId))
        #expect(!VocabularyWirePublicIntent.hasChanges(try cached.state.removingTag("absent")))
        #expect(change.removedBySense.count == 4 && change.removedBySense.values.allSatisfy { $0 == 1 })
        for table in ["notebook_entries", "notebook_senses", "notebook_collections"] {
            try f.db.core.executeScript(sql: """
                CREATE TEMP TRIGGER forbid_retiring_\(table) BEFORE DELETE ON \(table)
                BEGIN SELECT RAISE(ABORT,'Tag commands must retain owners'); END;
                """, errorContext: "Protect annotation owner identity")
        }
        let next = try f.db.removeNotebookTag("tagneedle", basedOn: saved)
        #expect(next.revision == saved.revision + 1)
        #expect(next.document.sources == saved.document.sources && next.document.interpretations == saved.document.interpretations)
        #expect(try f.db.browseNotebook(.init(tag: "tagneedle")).total == 0)
        #expect(try f.db.browseNotebook(.init(tag: "keep")).total == 4)
        #expect(try f.db.removeNotebookTag("tagneedle", basedOn: next) == next)
        #expect(throws: VocabularyError.editConflict) { try f.db.removeNotebookTag("keep", basedOn: saved) }
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == next)
    }

    @Test func largeTagDeltaRetainsEqualNonTagWordsAndReplaysMixedFrames() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let doc = document()
        var scope = try f.db.saveLingroveNotebook(doc, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let before = try f.db.prepareNotebookSearch()
        scope = try f.db.removeNotebookTag("tagneedle", basedOn: scope)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates", values: []) == 1)
        let hit = try f.db.prepareNotebookSearch(reusing: before)
        #expect(hit.preparation == .incremental)
        #expect(Set(try hit.results(matching: "tagneedle").entries.map(\.id)) == Set(doc.entries.prefix(4).map(\.id)))
        scope = try f.db.removeNotebookTag("Cafe\u{301}", basedOn: scope)
        let second = try f.db.prepareNotebookSearch(reusing: hit)
        #expect(second.preparation == .incremental)
        #expect(try second.results(matching: "cafe").entries.isEmpty)
        let detail = try f.db.notebookEntryDetail(entryID: doc.entries[100].id)
        var entry = try #require(detail.entry)
        entry.senses[0].note = "fresh context"; entry.senses[0].tags.append("brand-new-tag")
        _ = try f.db.saveNotebookEntry(entry, basedOn: detail)
        scope = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        scope = try f.db.removeNotebookTag("brand-new-tag", basedOn: scope)
        try f.reopen()
        let cold = try f.db.prepareNotebookSearch()
        #expect(cold.preparation == .incremental && f.db.core.notebookSaveCache == nil)
        let canonical = try f.db.notebookLiteralSearchMaterial()
        for query in ["", "tagneedle", "cafe", "brand-new-tag", "fresh context", "keep", "word119"] {
            #expect(try cold.results(matching: query).entries == canonical.results(matching: query).entries, "\(query)")
        }
    }

    @Test func lateTagDeltaFailureRollsBackCanonicalRowsAndTheFence() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(document(4), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER reject_tag_delta BEFORE INSERT ON notebook_literal_search_updates
            BEGIN SELECT RAISE(ABORT,'Synthetic late annotation delta failure'); END;
            """, errorContext: "Protect tag/delta atomicity")
        _ = try f.db.prepareNotebookSearch()
        let fence = try f.db.notebookBrowseFence()
        #expect(throws: (any Error).self) { try f.db.removeNotebookTag("tagneedle", basedOn: saved) }
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        #expect(try f.db.notebookBrowseFence() == fence)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates", values: []) == 0)
        try f.db.core.executeScript(sql: "DROP TRIGGER reject_tag_delta;", errorContext: "Retry annotation delta")
        let next = try f.db.removeNotebookTag("tagneedle", basedOn: saved)
        #expect(next.revision == saved.revision + 1)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == next)
    }

    @Test func oldCacheFormatsCannotReceiveNewTagFrames() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(document(4), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let material = try f.db.prepareNotebookSearch()
        var legacy = try #require(NotebookSearchBinaryCodec.encode(NotebookSearchProjection(material)))
        legacy.replaceSubrange(0..<4, with: [0x4c,0x47,0x53,0x32])
        try f.db.core.execute(sql: "UPDATE notebook_literal_search_cache SET format_version=2,payload=?,sha256=?",
            values: [.blob(legacy), .text(NotebookSearchCache.digest(legacy))])
        _ = try f.db.removeNotebookTag("tagneedle", basedOn: saved)
        #expect(try f.db.core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates", values: []) == 0)
        try f.reopen()
        #expect(try f.db.prepareNotebookSearch().preparation == .canonical)
        #expect(try f.db.core.scalarInt(sql: "SELECT format_version FROM notebook_literal_search_cache", values: []) == NotebookSearchCache.format)
        #expect(NotebookSearchBinaryCodec.decode(legacy) == nil)
    }
}
