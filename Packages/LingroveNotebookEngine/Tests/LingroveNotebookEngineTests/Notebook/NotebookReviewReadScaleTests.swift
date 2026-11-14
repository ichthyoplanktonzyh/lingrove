import Foundation
import SQLite3
import Testing
import LingroveNotebook
@testable import LingroveNotebookEngine

/// Count actual executed statements, rather than timing a fast machine. Increasing membership
/// may return more rows, but must not manufacture one SQL round trip per Card/property.
@MainActor
struct NotebookReviewReadScaleTests {
    private final class Probe { var statements = 0 }

    @Test func reviewReadUsesBoundedQueriesAcrossEnrollmentSizes() throws {
        var counts: [Int] = []
        for size in [5, 200] {
            let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
            let now = Date()
            let entries = (0..<size).map { index in
                VocabularyEntry(id: UUID(), expression: "word\(index)", dictionaryForm: "word\(index)",
                    language: .english, kind: .word,
                    senses: [.init(id: UUID(), meaning: "Meaning \(index)", createdAt: now, updatedAt: now)],
                    createdAt: now, updatedAt: now)
            }
            let scope = try f.db.saveLingroveNotebook(.init(entries: entries),
                basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
            _ = try f.db.enrollReviewNotes(selections: entries.map { .init(entryID: $0.id, senseID: $0.senses[0].id) },
                version: .init(scope))
            let probe = Probe()
            // SQLite borrows this test-owned object only during the synchronous read. The
            // callback is removed before the fixture or object can be retired.
            sqlite3_trace_v2(f.db.core.connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, _, _ in
                guard let context else { return 0 }
                Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().statements += 1
                return 0
            }, Unmanaged.passUnretained(probe).toOpaque())
            defer { sqlite3_trace_v2(f.db.core.connection, 0, nil, nil) }
            let content = try f.db.loadBuiltInNotebookReview(version: .init(scope), now: now, savedScope: scope)
            #expect(content.statistics.exercises == size && content.noteCards.count == size)
            counts.append(probe.statements)
        }
        #expect(counts.count == 2 && counts[1] <= counts[0] + 2 && counts[1] < 60)
    }
}
