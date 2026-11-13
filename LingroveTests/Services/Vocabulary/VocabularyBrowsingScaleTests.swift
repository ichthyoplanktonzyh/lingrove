import Combine
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Small deterministic fixtures protect the large-corpus seams: unchanged reads must not
/// repaint, aliases must still navigate, and UI state must not invalidate stored projections.
@MainActor
struct VocabularyBrowsingScaleTests {
    @Test func firstCaptureLookupBootstrapsOnlyAnEmptyNotebookAndShutdownRetiresReads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-empty-browse-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try MacNotebookRepository(databaseURL: folder.appendingPathComponent("primary.sqlite"),
            mediaDirectoryURL: folder.appendingPathComponent("Media"))
        let store = VocabularyStore(repository: repository)
        let capture = VocabularyCapture(expression: "new", dictionaryForm: "new", language: .english, kind: .word)
        #expect(await store.savedStatus(capture) == false)
        #expect(!store.isLoaded && store.entries.isEmpty && store.operationScope != nil && store.completeSnapshot == nil)
        store.browse(.init()); await store.browsing?.waitForPage()
        store.browsing?.loadTagsIfNeeded()
        // Cancel before the first metadata task can run. The replacement query must own a
        // new task rather than retaining the cancelled request as a permanent "in flight".
        store.browse(.init(language: .english)); await store.browsing?.waitForPage()
        await store.browsing?.waitForTags()
        #expect(store.browsing?.tagsReady == true && store.browsing?.tags.isEmpty == true)
        let identity = store.scopeIdentity
        try repository.engine.core.execute(sql: """
            UPDATE notebook_window_binding SET generation=lower(hex(randomblob(16))) WHERE settings_id=1
            """,
            values: [])
        #expect(await store.savedStatus(capture) == nil)
        #expect(store.scopeIdentity != identity)
        await store.browsing?.waitForPage()
        #expect(try store.browsing?.fence?.version == repository.version())
        #expect(await store.savedStatus(capture) == false)
        let io = try #require(store.browsing?.io)
        await store.shutdown()
        #expect(await store.savedStatus(capture) == nil)
        await #expect(throws: VocabularyError.editConflict) { try await io.page(.init()) }
        try repository.shutdown()
    }

    @Test func pagedReadAndExactSavedLookupLeaveFullStoreUnloadedUntilACommandNeedsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-paged-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("primary.sqlite"), now = Date()
        let archive = VocabularyArchive(url: url)
        let entries: [VocabularyEntry] = (0..<205).map { index in
            .init(id: UUID(), expression: "word\(index)", dictionaryForm: "word\(index)", language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: "meaning", tags: [index.isMultiple(of: 2) ? "even" : "odd"],
                    createdAt: now, updatedAt: now)],
                createdAt: now.addingTimeInterval(Double(index)), updatedAt: now)
        }
        _ = try await archive.commit(.init(entries: entries)); await archive.shutdown()
        let repository = try MacNotebookRepository(databaseURL: url, mediaDirectoryURL: folder.appendingPathComponent("Media"))
        let store = VocabularyStore(repository: repository), browse = try #require(store.browsing)
        #expect(store.operationScope != nil && !store.isLoaded && store.completeSnapshot == nil)
        store.browse(.init()); await browse.waitForPage()
        #expect(browse.isReady && browse.total == 205 && browse.entries.count == 100)
        #expect(!store.isLoaded && store.entries.isEmpty && store.operationScope == browse.fence?.version)
        #expect(await store.savedStatus(.init(expression: "word0", dictionaryForm: "word0", language: .english, kind: .word)) == true)
        #expect(await store.savedStatus(.init(expression: "absent", dictionaryForm: "absent", language: .english, kind: .word)) == false)
        #expect(!store.isLoaded)
        browse.select(entryID: entries[0].id); await browse.waitForDetail()
        #expect(browse.detail?.id == entries[0].id && store.entries.isEmpty)
        browse.loadMore(); await browse.waitForPage()
        #expect(browse.entries.count == 200 && Set(browse.entries.map(\.id)).count == 200)
        let original = try #require(browse.detail)
        var edited = original; edited.senses[0].note = "Cold scoped edit"
        #expect(await store.update(edited, basedOn: original, scope: store.operationScope))
        await browse.waitForPage()
        #expect(store.isLoaded && store.entries.count == 205 && browse.total == 205 && browse.entries.count == 200)
        #expect(store.readIndex.entriesByID[original.id]?.senses[0].note == "Cold scoped edit")
        store.browse(.init(tag: "even")); await browse.waitForPage()
        await browse.waitForDetail()
        #expect(browse.total == 103 && browse.entries.count == 100)
        #expect(browse.detail?.id == original.id)
        await store.shutdown(); try repository.shutdown()
    }

    @Test func literalDraftComparisonIgnoresMembersButPreservesAuthoredBytesAndBodyOrder() throws {
        let now = Date()
        let examples = ["First", "Second"].map {
            VocabularyExample(id: UUID(), text: $0, translation: "", ranges: [], completeness: .sentence,
                meaning: "", createdAt: now)
        }
        let blocks = ["Before", "After"].map { VocabularyContentBlock(content: .text(.init(text: $0))) }
        let first = VocabularySense(id: UUID(), meaning: "one", note: "caf\u{00e9}", examples: examples,
            content: blocks, createdAt: now, updatedAt: now)
        let second = VocabularySense(id: UUID(), meaning: "two", createdAt: now, updatedAt: now)
        let entry = VocabularyEntry(id: UUID(), expression: "word", dictionaryForm: "word", language: .english,
            kind: .word, senses: [first, second], createdAt: now, updatedAt: now)
        var reversed = entry
        reversed.senses[0].examples.reverse(); reversed.senses.reverse()
        #expect(try VocabularySaveLiteralEquality.equal(entry, reversed))
        reversed = entry; reversed.senses[0].note = "cafe\u{0301}"
        #expect(entry == reversed)
        #expect(try !VocabularySaveLiteralEquality.equal(entry, reversed))
        reversed = entry; reversed.senses[0].content?.reverse()
        #expect(try !VocabularySaveLiteralEquality.equal(entry, reversed))
    }

    @Test func batchIndexChangeRetiresAllOldOwnersBeforeInstallingSwappedKeys() throws {
        let now = Date(), alias = UUID()
        let entries = ["harbor", "forest"].map { word in
            VocabularyEntry(id: UUID(), expression: word, dictionaryForm: word, language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: word, tags: [word], createdAt: now, updatedAt: now)],
                createdAt: now, updatedAt: now)
        }
        var old = entries
        old[0].senses[0].mergedFrom = [alias]
        var changed = old
        changed[0].expression = "forest"; changed[0].dictionaryForm = "forest"
        changed[1].expression = "harbor"; changed[1].dictionaryForm = "harbor"
        changed[0].senses[0].mergedFrom = []; changed[1].senses[0].mergedFrom = [alias]
        var index = VocabularyReadIndex(entries: old)
        index.apply(updatedEntries: changed, removing: [])
        #expect(index.entries == changed)
        for entry in changed { #expect(index.entry(forKey: VocabularyPolicy.entryKey(entry))?.id == entry.id) }
        #expect(index.entry(forSense: alias)?.id == changed[1].id)
        #expect(index.allTags == ["forest", "harbor"])
        index.apply(updatedEntries: [old[0]], removing: [old[1].id])
        #expect(index.entries == [old[0]])
        #expect(index.entry(forSense: alias)?.id == old[0].id)
        #expect(index.allTags == ["harbor"])
    }

    @Test func readOnlyCommandsDoNotRepublishAnAcknowledgedRevision() async throws {
        let archive = VocabularyArchive(url: nil)
        let store = VocabularyStore(archive: archive)
        await store.save(.init(expression: "harbor", dictionaryForm: "harbor", language: .english, kind: .word, meaning: "港口"))
        let before = store.contentRevision, scope = store.currentRevision
        var publications = 0
        let observer = store.$entries.dropFirst().sink { _ in publications += 1 }
        for _ in 0..<3 {
            let reply = await store.executeCLI(.init(command: .status))
            #expect(reply.ok)
        }
        #expect(publications == 0 && store.contentRevision == before && store.currentRevision == scope)
        let entry = try #require(store.entries.first)
        var edited = entry; edited.senses[0].note = "An explicit edit"
        #expect(await store.update(edited, basedOn: entry))
        #expect(publications == 1 && store.contentRevision != before)
        observer.cancel(); await store.shutdown()
    }

    @Test func firstEmptyRevisionStillLoadsAndMergedAliasesResolve() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        await store.load()
        #expect(store.isLoaded && store.entries.isEmpty)
        let now = Date(), alias = UUID(), id = UUID()
        let entry = VocabularyEntry(id: UUID(), expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            senses: [.init(id: id, meaning: "shore", tags: ["nature"], mergedFrom: [alias], createdAt: now, updatedAt: now)],
            createdAt: now, updatedAt: now)
        let index = VocabularyReadIndex(entries: [entry])
        #expect(index.entry(forSense: alias)?.id == entry.id)
        #expect(index.selectionsBySenseID[alias]?.senseID == id)
        #expect(index.allTags == ["nature"])
        await store.shutdown()
    }

    @Test func disclosureAndFilteringHaveStableRowsAndEditsKeepCreationOrder() async throws {
        let archive = VocabularyArchive(url: nil), now = Date()
        let first = VocabularyEntry(id: UUID(), expression: "first", dictionaryForm: "first", language: .english, kind: .word,
            senses: [.init(id: UUID(), meaning: "one", createdAt: now, updatedAt: now),
                     .init(id: UUID(), meaning: "two", createdAt: now, updatedAt: now)],
            createdAt: now, updatedAt: now.addingTimeInterval(50))
        let second = VocabularyEntry(id: UUID(), expression: "second", dictionaryForm: "second", language: .french, kind: .word,
            senses: [.init(id: UUID(), meaning: "three", createdAt: now, updatedAt: now)],
            createdAt: now.addingTimeInterval(10), updatedAt: now.addingTimeInterval(10))
        _ = try await archive.commit(.init(entries: [first, second]))
        let store = VocabularyStore(archive: archive); await store.load()
        let cache = VocabularyBrowserCache()
        let entries = cache.entries(store: store, language: nil, tag: "", newestFirst: true)
        #expect(entries.map(\.id) == [second.id, first.id])
        let collapsed = cache.listRows(entries: cache.matching(entries, query: ""), expanded: [])
        let expanded = cache.listRows(entries: entries, expanded: [first.id])
        #expect(collapsed.count == 2 && expanded.count == 4)
        #expect(expanded.map(\.id).prefix(2) == collapsed.map(\.id).prefix(2))
        let filtered = cache.entries(store: store, language: .french, tag: "", newestFirst: true)
        #expect(cache.listRows(entries: filtered, expanded: [first.id]).count == 1)
        await store.shutdown()
    }
}
