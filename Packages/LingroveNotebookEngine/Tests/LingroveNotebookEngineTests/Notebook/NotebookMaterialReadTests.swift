import Foundation
import LingroveNotebook
import SQLite3
import Testing
@testable import LingroveNotebookEngine

/// Private SQLite fixtures compare scoped reads with the complete public projection. A read
/// must not populate the writer's whole-corpus proof or mutate the durable corpus clock.
@MainActor
struct NotebookMaterialReadTests {
    @Test func selectedReadsPreserveOrderEvidenceAndClassificationWithoutFullLoad() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let entries = (0..<4).map { makeEntry("word\($0)") }
        var document = VocabularyDocument(entries: entries)
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Concept")])
        document.semantics.nodes = [node]
        document.semantics.mappings = [.init(nodeID: node.id, senseID: entries[0].senses[0].id,
            evidenceIDs: [entries[0].examples[0].id])]
        let category = VocabularyCategory(id: UUID(), axis: .content, labels: [.init(text: "Group")])
        let membership = VocabularyMeaningCategoryMembership(id: UUID(), nodeID: node.id, categoryID: category.id)
        document.classification.categories = [category]; document.classification.memberships = [membership]
        let saved = try fixture.db.saveLingroveNotebook(document,
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.reopen()
        let before = try fixture.db.notebookChanges()
        let oracle = try LingroveNotebookEngine(databaseURL: fixture.url, mediaDirectoryURL: fixture.directory)
        defer { try? oracle.close() }
        let complete = try oracle.loadLingroveNotebook(workspaceId: fixture.workspace).document
        let projection = NotebookSenseProjection(complete)
        let ids = [entries[2].id, entries[0].id]
        let read = try fixture.db.readNotebookMaterial(ids: ids, includeClassification: true)
        #expect(read.entries.map(\.id) == ids)
        #expect(read.categoryMemberships == [.object(["id": .string(membership.id.uuidString),
            "nodeID": .string(node.id.uuidString), "categoryID": .string(category.id.uuidString), "key": .null])])
        #expect(read.values == (try ids.map { id in
            try projection.entry(#require(complete.entries.first { $0.id == id }))
        }))
        let senses = [entries[0].senses[1].id, entries[0].senses[0].id]
        #expect(try fixture.db.readNotebookMaterial(ids: senses, selectingSenses: true).values == senses.map { try projection.sense($0) })
        #expect(throws: (any Error).self) { try fixture.db.readNotebookMaterial(ids: [ids[0], UUID()]) }
        #expect(throws: (any Error).self) { try fixture.db.readNotebookMaterial(ids: [senses[0], UUID()], selectingSenses: true) }
        let counts = try fixture.db.notebookCorpusCounts()
        #expect(counts.counts["entryCount"] == 4 && counts.counts["senseCount"] == 8)
        #expect(counts.version == .init(saved))
        #expect(fixture.db.core.notebookSaveCache == nil)
        #expect(try fixture.db.notebookChanges().stamp == before.stamp)
    }

    @Test func summaryPagesHaveGlobalCountsLanguageFiltersAndBoundedContent() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let entries = [makeEntry(String(repeating: "语", count: 250)), makeEntry("second", language: .french), makeEntry("third")]
        _ = try fixture.db.saveLingroveNotebook(.init(entries: entries),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.reopen()
        let first = try fixture.db.readNotebookSummaryPage(limit: 2)
        let second = try fixture.db.readNotebookSummaryPage(limit: 2, offset: 2)
        #expect(first.total == 3 && first.values.count == 2 && second.values.count == 1)
        let values = first.values + second.values
        let ids = values.compactMap { value -> String? in
            guard case let .object(object) = value, case let .string(id) = object["entryID"] else { return nil }
            return id
        }
        #expect(ids == entries.map { $0.id.uuidString }.sorted())
        for case let .object(value) in values {
            #expect(value["senseCount"] == .integer(2))
            guard case let .array(senses) = value["senses"] else { Issue.record("Missing summaries"); continue }
            for case let .object(sense) in senses { #expect(sense["exampleCount"] == .integer(1)) }
            if value["expressionTruncated"] == .bool(true) {
                #expect(value["expression"] == .string(String(repeating: "语", count: 200)))
            }
        }
        #expect(try fixture.db.readNotebookSummaryPage(language: "fr").total == 1)
        #expect(try fixture.db.readNotebookSummaryPage(offset: 99).values.isEmpty)
        #expect(fixture.db.core.notebookSaveCache == nil)
    }

    @Test func summarySenseSQLDoesNotWalkUnrelatedParentsToSatisfyIDOrder() throws {
        func work(_ count: Int) throws -> Int {
            let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
            let entries = (0..<count).map { makeEntry("word\($0)") }
            _ = try fixture.db.saveLingroveNotebook(.init(entries: entries),
                basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
            let probe = MaterialReadSQLWork()
            sqlite3_trace_v2(fixture.db.core.connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)),
                      String(cString: sql).contains("SELECT s.id,s.meaning,") else { return 0 }
                let probe = Unmanaged<MaterialReadSQLWork>.fromOpaque(context).takeUnretainedValue()
                probe.steps += Int(sqlite3_stmt_status(OpaquePointer(statement), SQLITE_STMTSTATUS_VM_STEP, 0))
                return 0
            }, Unmanaged.passUnretained(probe).toOpaque())
            defer { sqlite3_trace_v2(fixture.db.core.connection, 0, nil, nil) }
            #expect(try fixture.db.readNotebookSummaryPage(limit: 10, offset: count / 2).values.count == 10)
            return probe.steps
        }
        let small = try work(100), large = try work(2_000)
        #expect(small > 0 && large < small * 2, "Selected sense SQL VM steps: \(small) / \(large)")
    }

    @Test func countsReuseOnlyTheCurrentCheckedCacheAndRawChangesForceSQLCounts() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        _ = try fixture.db.saveLingroveNotebook(.init(entries: [makeEntry("counted")]),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        let probe = MaterialReadSQLWork()
        sqlite3_trace_v2(fixture.db.core.connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)),
                  String(cString: sql).contains("SELECT COUNT(*) FROM notebook_") else { return 0 }
            Unmanaged<MaterialReadSQLWork>.fromOpaque(context).takeUnretainedValue().counts += 1
            return 0
        }, Unmanaged.passUnretained(probe).toOpaque())
        defer { sqlite3_trace_v2(fixture.db.core.connection, 0, nil, nil) }
        let warm = try fixture.db.notebookCorpusCounts()
        #expect(warm.counts["senseCount"] == 2 && probe.counts == 0)
        // A raw evidence-status change advances the corpus clock without the header. A
        // version-only cache check would silently trust a stale baseline here.
        try fixture.db.core.execute(sql: """
            UPDATE notebook_usages SET status='rejected',payload_json=json_set(payload_json,'$.status','rejected')
            WHERE workspace_id=?
            """,
            values: [.text(fixture.workspace)])
        #expect(try fixture.db.notebookCorpusCounts().counts == warm.counts)
        #expect(probe.counts == 5)
    }

    private func makeEntry(_ expression: String, language: LearningLanguage = .english) -> VocabularyEntry {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let senses = (0..<2).map { number in
            VocabularySense(id: UUID(), meaning: "Meaning \(number)", examples: [.init(id: UUID(),
                text: "A complete sentence.", translation: "例句", ranges: [], completeness: .sentence,
                meaning: "", createdAt: now)], createdAt: now, updatedAt: now)
        }
        return .init(id: UUID(), expression: expression, dictionaryForm: expression, language: language,
            kind: .word, senses: senses, createdAt: now, updatedAt: now)
    }
}

/// The synchronous test owns the SQLite callback context until trace removal in defer.
private final class MaterialReadSQLWork {
    var steps = 0
    var counts = 0
}
