import Combine
import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

/// Small deterministic fixtures protect the large-corpus seams: unchanged reads must not
/// repaint, aliases must still navigate, and UI state must not invalidate stored projections.
@MainActor
struct VocabularyBrowsingScaleTests {
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
