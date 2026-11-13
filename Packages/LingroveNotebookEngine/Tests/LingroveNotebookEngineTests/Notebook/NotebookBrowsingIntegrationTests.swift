import Foundation
import LingroveNotebook
import SQLite3
import Testing
@testable import LingroveNotebookEngine

/// Actual SQLite pages protect global query semantics and read fences without simulating UI
/// clicks. A fresh read-only connection must never establish the writer's whole-corpus proof.
@MainActor
struct NotebookBrowsingIntegrationTests {
    @Test func detailSQLWorkStaysBoundedWhenUnrelatedRowsGrow() throws {
        func work(_ count: Int) throws -> Int {
            let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
            let entries = makeEntries(count)
            _ = try fixture.db.saveLingroveNotebook(.init(entries: entries),
                basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
            let reader = try LingroveNotebookEngine(readOnlyDatabaseURL: fixture.url, mediaDirectoryURL: fixture.directory)
            defer { try? reader.close() }
            let probe = NotebookBrowseSQLWork()
            sqlite3_trace_v2(reader.core.connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement else { return 0 }
                let probe = Unmanaged<NotebookBrowseSQLWork>.fromOpaque(context).takeUnretainedValue()
                probe.steps += Int(sqlite3_stmt_status(OpaquePointer(statement), SQLITE_STMTSTATUS_VM_STEP, 0))
                return 0
            }, Unmanaged.passUnretained(probe).toOpaque())
            defer { sqlite3_trace_v2(reader.core.connection, 0, nil, nil) }
            #expect(try reader.notebookEntryDetail(entryID: entries[0].id).entry == entries[0])
            return probe.steps
        }
        let small = try work(100), large = try work(2_000)
        #expect(small > 0 && large < small * 2, "A selected entry must not walk every unrelated workspace row")
    }

    @Test func pagesCoverGlobalCorpusAndFiltersWithoutLoadingEvidence() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let entries = makeEntries(205)
        _ = try fixture.db.saveLingroveNotebook(.init(entries: entries),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        let reader = try LingroveNotebookEngine(readOnlyDatabaseURL: fixture.url, mediaDirectoryURL: fixture.directory)
        defer { try? reader.close() }
        let before = try reader.notebookChanges()
        var page = try reader.browseNotebook()
        #expect(page.total == 205 && page.entries.count == 100 && page.decodedRows == 300)
        #expect(page.entries.allSatisfy { $0.senses.contains { $0.title == "First paragraph" } })
        var ids = page.entries.map(\.id)
        while let cursor = page.next {
            page = try reader.browseNotebook(after: cursor)
            ids += page.entries.map(\.id)
        }
        #expect(ids.count == 205 && Set(ids).count == 205)
        #expect(ids == entries.map(\.id).sorted { $0.uuidString < $1.uuidString })
        let french = try reader.browseNotebook(.init(language: .french, tag: "one"))
        #expect(french.total == 102)
        #expect(french.entries.allSatisfy { $0.language == .french && $0.senses.count == 1 })
        #expect(try reader.notebookChanges().stamp == before.stamp)
        #expect(reader.core.notebookSaveCache == nil)
    }

    @Test func detailJoinsOnlyItsCompleteEvidenceAndAliasLookupFindsUnpagedEntry() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let original = makeEntries(110)
        let saved = try fixture.db.saveLingroveNotebook(.init(entries: original),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        let reader = try LingroveNotebookEngine(readOnlyDatabaseURL: fixture.url, mediaDirectoryURL: fixture.directory)
        defer { try? reader.close() }
        let page = try reader.browseNotebook()
        let target = try #require(saved.document.entries.first { !Set(page.entries.map(\.id)).contains($0.id) })
        let detail = try reader.notebookEntryDetail(entryID: target.id, expected: page.fence)
        #expect(detail.entry == target && detail.decodedRows < 40)
        let alias = try #require(target.senses.first?.mergedFrom.first)
        #expect(try reader.notebookEntryDetail(senseID: alias).entry == target)
        #expect(try reader.notebookEntryDetail(lookupKey: VocabularyIdentityPolicy.entryKey(target)).entry == target)
        #expect(try reader.notebookEntryDetail(entryID: UUID()).entry == nil)
        #expect(try reader.notebookBrowseTags(expected: page.fence) == ["one", "two"])
        #expect(reader.core.notebookSaveCache == nil)
    }

    @Test func cursorRejectsDifferentQueriesRawSameRevisionEditsAndGenerationChanges() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        _ = try fixture.db.saveLingroveNotebook(.init(entries: makeEntries(4)),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        let page = try fixture.db.browseNotebook(limit: 1), cursor = try #require(page.next)
        #expect(throws: VocabularyError.editConflict) { try fixture.db.browseNotebook(.init(newestFirst: false), after: cursor) }
        try fixture.db.core.execute(sql: "UPDATE notebook_entries SET expression=expression || ' changed' WHERE workspace_id=? AND id=?",
            values: [.text(fixture.workspace), .text(page.entries[0].id.uuidString)])
        #expect(throws: VocabularyError.editConflict) { try fixture.db.browseNotebook(after: cursor) }
        #expect(throws: VocabularyError.editConflict) {
            try fixture.db.notebookEntryDetail(entryID: page.entries[0].id, expected: page.fence)
        }
        let newer = try fixture.db.browseNotebook(limit: 1)
        try fixture.db.core.execute(sql: "UPDATE notebook_window_binding SET generation=lower(hex(randomblob(16))) WHERE settings_id=1",
            values: [])
        #expect(throws: VocabularyError.editConflict) { try fixture.db.browseNotebook(after: newer.next) }
    }

    @Test func detailRejectsIndexPayloadDisagreementInsteadOfSilentlyDroppingRows() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let entry = makeEntries(1)[0]
        _ = try fixture.db.saveLingroveNotebook(.init(entries: [entry]),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.db.core.execute(sql: "UPDATE notebook_senses SET meaning='wrong index' WHERE workspace_id=?",
            values: [.text(fixture.workspace)])
        #expect(throws: VocabularyError.invalidArchive) { try fixture.db.notebookEntryDetail(entryID: entry.id) }
    }

    @Test func detailImagesRequireTheSelectedSubtreeWorkspaceAndExactFence() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        var document = LingroveNotebookMediaQueueIntegrationTests.document(image.reference)
        document.catalog[0].senses[0].meaning = ""
        let entryID = document.catalog[0].id
        _ = try fixture.db.saveLingroveNotebook(document,
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace),
            images: [image.reference.filename: image.data])
        let reader = try LingroveNotebookEngine(readOnlyDatabaseURL: fixture.url, mediaDirectoryURL: fixture.db.core.mediaDirectoryURL)
        defer { try? reader.close() }
        let page = try reader.browseNotebook()
        #expect(page.entries[0].senses[0].hasImage && page.entries[0].senses[0].title.isEmpty)
        let detail = try reader.notebookEntryDetail(entryID: entryID)
        #expect(try reader.notebookEntryImage(image.reference, detail: detail) == image.data)
        try fixture.db.core.execute(sql: "UPDATE notebook_window_binding SET generation=lower(hex(randomblob(16))) WHERE settings_id=1",
            values: [])
        #expect(throws: VocabularyError.editConflict) { try reader.notebookEntryImage(image.reference, detail: detail) }
        #expect(reader.core.notebookSaveCache == nil)
    }

    private func makeEntries(_ count: Int) -> [VocabularyEntry] {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        return (0..<count).map { index in
            let senses = (0..<2).map { number in
                VocabularySense(id: UUID(), meaning: number == 0 ? "Meaning 0" : "", note: "Retained note",
                    tags: [number == 0 ? "one" : "two"],
                    examples: [.init(id: UUID(), text: "A complete source sentence.", translation: "例句", ranges: [],
                        completeness: .sentence, meaning: "", createdAt: now)], mergedFrom: [UUID()],
                    content: [.init(content: .text(.init(text: "First paragraph"))),
                              .init(content: .text(.init(text: "Second paragraph")))],
                    createdAt: now, updatedAt: now)
            }
            return .init(id: UUID(), expression: "word\(index)", dictionaryForm: "word\(index)",
                language: index.isMultiple(of: 2) ? .english : .french,
                kind: .word, senses: senses, createdAt: now, updatedAt: now)
        }
    }
}

/// One synchronous test owns this callback context until trace removal in defer. The engine
/// serializes its connection, so no concurrent access or callback outliving this value occurs.
private final class NotebookBrowseSQLWork {
    var steps = 0
}
