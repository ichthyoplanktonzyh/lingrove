import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookPersistenceCodec
import LingroveStudyExport
import Testing
@testable import Lingrove

/// Opt-in Release operation inventory. This test calls production commands and presentation
/// models without opening windows or synthesizing clicks. Results and saved postconditions are
/// checked; recorded rejections stay separate. Fresh seeds isolate trials. Model inference,
/// network services and actual frame drawing are intentionally outside these local timings.
@Suite(.serialized, .timeLimit(.minutes(60)))
@MainActor
struct VocabularyOperationBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_OPERATION_BENCHMARK_OUTPUT"] != nil))
    func measureSyntheticOperations() async throws {
        try #require(Bundle.main.object(forInfoDictionaryKey: "LingroveIsolatedValidationHost") as? Bool == true)
        #if DEBUG
        Issue.record("Operation timings require a Release build")
        return
        #endif
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try #require(environment["LINGROVE_OPERATION_BENCHMARK_OUTPUT"]))
            .standardizedFileURL
        try #require(output.path.hasPrefix("/Users/shadow/lingrove/build/"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sizes = (environment["LINGROVE_OPERATION_BENCHMARK_SIZES"] ?? "100,10000,20000")
            .split(separator: ",").compactMap { Int($0) }
        let trials = Int(environment["LINGROVE_OPERATION_BENCHMARK_TRIALS"] ?? "5") ?? 5
        let focused = environment["LINGROVE_OPERATION_BENCHMARK_MODE"] == "focused"
        let tail = environment["LINGROVE_OPERATION_BENCHMARK_MODE"] == "tail"
        let remaining = environment["LINGROVE_OPERATION_BENCHMARK_MODE"] == "remaining"
        let paged = environment["LINGROVE_OPERATION_BENCHMARK_MODE"] == "paged"
        try #require(!sizes.isEmpty && sizes.allSatisfy { $0 >= 100 && $0 <= 20_000 } && (1...10).contains(trials))
        for size in sizes {
            let seed = output.appendingPathComponent("seed-\(size)")
            var counts = try VocabularyBenchmarkFixture.seed(entries: size, at: seed)
            counts["databaseBytes"] = try seed.appendingPathComponent("primary.sqlite")
                .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try JSONEncoder().encode(counts).write(to: output.appendingPathComponent("fixture-\(size).json"))
            for trial in 1...trials {
                let fixture = try VocabularyBenchmarkFixture(seed: seed.appendingPathComponent("primary.sqlite"),
                    directory: output.appendingPathComponent("trial-\(size)-\(trial)"))
                let recorder = VocabularyBenchmarkRecorder(entries: size, trial: trial, output: output)
                do {
                    if paged {
                        try await runPaged(fixture, recorder, seed: seed.appendingPathComponent("primary.sqlite"))
                    } else if remaining {
                        try await runRemaining(fixture, recorder)
                    } else if tail { try await runTail(fixture, recorder) } else {
                        try await run(fixture, recorder, focused: focused)
                    }
                    await fixture.close()
                } catch {
                    await fixture.close()
                    throw error
                }
            }
            if remaining {
                let folder = output.appendingPathComponent("profile-\(size)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let fixture = try VocabularyBenchmarkFixture(seed: seed.appendingPathComponent("primary.sqlite"),
                    directory: folder.appendingPathComponent("fixture"))
                do {
                    try await profilePersistence(fixture, .init(entries: size, trial: 1, output: folder))
                    await fixture.close()
                } catch {
                    await fixture.close()
                    throw error
                }
            }
            try FileManager.default.removeItem(at: seed)
        }
    }

    /// Page-ready and full-store-ready are different user-visible milestones. Cold commands
    /// use separate copies of the same closed seed; no preceding warm-up hides their full-load
    /// fallback. Every timer invokes production actors/models, without windows or clicks.
    private func runPaged(_ fixture: VocabularyBenchmarkFixture, _ recorder: VocabularyBenchmarkRecorder, seed: URL) async throws {
        let browse = try #require(fixture.store.browsing)
        recorder.visibleEntries = { browse.entries.count }
        try await recorder.measure("browse.first.page", layer: "model") {
            fixture.store.browse(.init()); await browse.waitForPage()
        }
        try #require(browse.isReady && browse.error == nil && browse.total == recorder.entries && browse.entries.count == 100)
        #expect(fixture.store.entries.isEmpty && !fixture.store.isLoaded)
        try recorder.outcome("browse.first.page.rows", succeeded: browse.decodedRows == 300,
            message: "\(browse.decodedRows) summary rows; zero evidence payload decodes")
        try await recorder.measure("browse.next.page", layer: "model") { browse.loadMore(); await browse.waitForPage() }
        try #require(browse.entries.count == min(200, recorder.entries))
        let target = VocabularyBenchmarkFixture.id(1_000_042)
        try await recorder.measure("browse.entry.detail", layer: "model") { browse.select(entryID: target); await browse.waitForDetail() }
        let detail = try #require(browse.detail)
        #expect(detail.id == target && detail.senses.count == 2 && detail.examples.count == 4)
        try recorder.outcome("browse.entry.detail.rows", succeeded: browse.detailDecodedRows < 100,
            message: "\(browse.detailDecodedRows) payload rows for one entry")
        let capture = VocabularyBenchmarkFixture.capture("word42")
        let saved = try await recorder.measure("browse.saved.lookup", layer: "model") { await fixture.store.savedStatus(capture) }
        #expect(saved == true && !fixture.store.isLoaded && fixture.store.entries.isEmpty)
        try await recorder.measure("browse.filter.page", layer: "model") {
            fixture.store.browse(.init(language: .english, tag: "group-2")); await browse.waitForPage()
        }
        try #require(browse.isReady && browse.total == recorder.entries / 20 && browse.entries.count == min(100, recorder.entries / 20))
        let fresh = VocabularyBenchmarkFixture.capture("paged-cold-favorite-\(recorder.trial)")
        try await recorder.measure("favorite.cold.first", layer: "store") { await fixture.store.save(fresh) }
        let receipt = try #require(fixture.store.lastEntryCommit)
        try #require(!fixture.store.isLoaded && fixture.store.entries.isEmpty)
        #expect(await fixture.store.savedStatus(fresh) == true)
        #expect(try fixture.repository.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries WHERE workspace_id=?",
            values: [.text(receipt.version.workspaceId)]) == recorder.entries + 1)
        #expect(try fixture.repository.engine.loadReviewEventCount() == 1_000)
        let deleted = try VocabularyBenchmarkFixture(seed: seed, directory: fixture.directory.appendingPathComponent("cold-delete"))
        do {
            let removed = try await recorder.measure("sense.remove.cold.first", layer: "store") {
                await deleted.store.removeSense(entryID: target, senseID: VocabularyBenchmarkFixture.id(2_000_084))
            }
            try #require(removed && !deleted.store.isLoaded && deleted.store.entries.isEmpty)
            #expect(deleted.store.lastEntryCommit?.entry?.senses.count == 1)
            let version = try #require(deleted.store.operationScope)
            #expect(try deleted.repository.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries WHERE workspace_id=?",
                values: [.text(version.workspaceId)]) == recorder.entries)
            #expect(try deleted.repository.engine.loadReviewEventCount() == 1_000)
            await deleted.close()
        } catch { await deleted.close(); throw error }
        try await coldEntryCases(fixture, recorder, seed: seed)
        let full = try VocabularyBenchmarkFixture(seed: seed, directory: fixture.directory.appendingPathComponent("cold-full"))
        try await recorder.measure("corpus.full.ready", layer: "model") { await full.store.load() }
        #expect(full.store.isLoaded && full.store.entries.count == recorder.entries)
        await full.close()
    }

    /// Fresh capture/retirement cases share the closed seed without a full-load warm-up.
    /// Missing-proof fallback stays explicit rather than disappearing into eligible medians.
    private func coldEntryCases(_ fixture: VocabularyBenchmarkFixture, _ recorder: VocabularyBenchmarkRecorder,
                                seed: URL) async throws {
        for existing in [false, true] {
            let label = existing ? "existing-sense" : "context"
            let cold = try VocabularyBenchmarkFixture(seed: seed, directory: fixture.directory.appendingPathComponent(label))
            do {
                var capture = VocabularyBenchmarkFixture.capture(existing ? "word42" : "new-context", example: true)
                if existing { capture.senseID = VocabularyBenchmarkFixture.id(2_000_084) }
                try await recorder.measure("favorite.cold." + label) { await cold.store.save(capture) }
                try #require(!cold.store.isLoaded && cold.store.lastEntryCommit != nil)
                #expect(await cold.store.savedStatus(capture) == true)
                #expect(cold.store.lastEntryCommit?.entry?.examples.count == (existing ? 5 : 1))
                #expect(try cold.repository.engine.loadReviewEventCount() == 1_000)
                await cold.close()
            } catch { await cold.close(); throw error }
        }
        let reviewed = try VocabularyBenchmarkFixture(seed: seed, directory: fixture.directory.appendingPathComponent("review-retirement"))
        do {
            let version = try #require(reviewed.store.operationScope)
            let cardID = try #require(try reviewed.repository.engine.core.scalarOptionalText(sql: """
                SELECT card_id FROM notebook_card_links WHERE workspace_id=? AND notebook_id=? AND sense_id=? AND deleted_at IS NULL LIMIT 1
                """, values: [.text(version.workspaceId), .text(version.notebookId.uuidString),
                    .text(VocabularyBenchmarkFixture.id(2_000_080).uuidString)]))
            let card = try reviewed.repository.engine.loadActiveCard(workspaceId: version.workspaceId, cardId: cardID)
            let removed = try await recorder.measure("sense.remove.cold.enrolled") {
                await reviewed.store.removeSense(entryID: VocabularyBenchmarkFixture.id(1_000_040),
                    senseID: VocabularyBenchmarkFixture.id(2_000_080))
            }
            try #require(removed && !reviewed.store.isLoaded && reviewed.store.entries.isEmpty)
            #expect(reviewed.store.lastEntryCommit?.entry?.senses.count == 1)
            #expect(try reviewed.repository.engine.loadActiveCard(workspaceId: version.workspaceId, cardId: cardID) == card)
            #expect(try reviewed.repository.engine.core.scalarOptionalText(sql: """
                SELECT status FROM notebook_review_material_state WHERE workspace_id=? AND card_id=?
                """, values: [.text(version.workspaceId), .text(cardID)]) == "sourceMissing")
            #expect(try reviewed.repository.engine.loadReviewEventCount() == 1_000)
            await reviewed.close()
        } catch { await reviewed.close(); throw error }
        let unprepared = try VocabularyBenchmarkFixture(seed: seed, directory: fixture.directory.appendingPathComponent("proof-fallback"))
        do {
            try unprepared.repository.engine.core.execute(sql: "DELETE FROM notebook_entry_checkpoint", values: [])
            let capture = VocabularyBenchmarkFixture.capture("missing-proof")
            try await recorder.measure("favorite.cold.missing-proof-fallback") { await unprepared.store.save(capture) }
            try #require(unprepared.store.isLoaded && unprepared.store.contains(capture))
            #expect(try unprepared.repository.engine.loadReviewEventCount() == 1_000)
            await unprepared.close()
        } catch { await unprepared.close(); throw error }
        try await certifiedWriterCases(fixture, recorder, seed: seed)
    }

    /// One closed post-sync seed feeds both cold cases. Only the derived certificate is
    /// removed in the control; account/content/history and all earlier setup are identical.
    private func certifiedWriterCases(
        _ fixture: VocabularyBenchmarkFixture, _ recorder: VocabularyBenchmarkRecorder, seed: URL
    ) async throws {
        let folder = fixture.directory.appendingPathComponent("validated-writer-seed")
        let prepared = try VocabularyBenchmarkSyncSeed.prepare(from: seed, at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        for retainProof in [true, false] {
            let label = retainProof ? "proof" : "control"
            let cold = try VocabularyBenchmarkFixture(seed: prepared,
                directory: fixture.directory.appendingPathComponent("post-sync-" + label))
            do {
                if !retainProof {
                    try cold.repository.engine.core.execute(sql: "DELETE FROM notebook_entry_checkpoint", values: [])
                }
                let capture = VocabularyBenchmarkFixture.capture("after-validated-sync")
                let operation = retainProof ? "favorite.cold.after-validated-sync" : "favorite.cold.after-sync-proof-removed"
                try await recorder.measure(operation) { await cold.store.save(capture) }
                #expect(await cold.store.savedStatus(capture) == true)
                if retainProof {
                    try #require(!cold.store.isLoaded && cold.store.lastEntryCommit != nil && cold.store.entries.isEmpty)
                } else { try #require(cold.store.isLoaded && cold.store.contains(capture)) }
                #expect(try cold.repository.engine.loadReviewEventCount() == 1_000)
                await cold.close()
            } catch { await cold.close(); throw error }
        }
    }

    /// Component windows run on a separate fresh copy after the three operation trials. Their
    /// boundaries deliberately overlap; they locate CPU work and must not be summed into load.
    /// The profile keeps only synthetic in-memory rows and publishes durations/counts.
    private func profilePersistence(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        let snapshot = try await r.measure("cold.engine.load", layer: "engine") { try f.repository.snapshot() }
        let state = try await r.measure("cold.domain.validate.index", layer: "policy") {
            try VocabularyEntrySaveState(validating: snapshot.document)
        }
        let joined = try await r.measure("cold.domain.join", layer: "policy") { snapshot.document.entries }
        #expect(joined == state.entries && joined.count == r.entries)
        let prepared = try await r.measure("full.domain.prepare", layer: "policy") {
            try VocabularyEntrySaveState(preparing: snapshot.document, previous: state)
        }
        #expect(prepared.document == snapshot.document)
        let rows = try await r.measure("full.codec.encode.sort", layer: "codec") {
            try VocabularyPersistenceCodec.encode(state)
        }
        struct Input {
            let row: VocabularyPersistenceRow
            let data: Data
            let indexes: [VocabularyPersistenceIndex: String?]
        }
        let inputs = try rows.rows.map { Input(row: $0, data: try $0.encodedPayload(), indexes: $0.indexValues) }
        let decoded = try await r.measure("cold.row.payload.decode", layer: "codec") {
            try inputs.map { input in
                try VocabularyPersistenceRow(entity: input.row.entity, id: input.row.id,
                    parentID: input.row.parentID, position: input.row.position, payload: input.data, indexValues: input.indexes)
            }
        }
        let encoded = VocabularyPersistenceRows(rows: decoded)
        let restored = try await r.measure("cold.rows.reconstruct.validate", layer: "codec") {
            try VocabularyPersistenceCodec.decodeSaveState(encoded)
        }
        #expect(restored.document == snapshot.document)
        let projection = try await r.measure("cold.row.cache", layer: "codec") { try VocabularyEntryRowProjection(encoded) }
        let delta = try await r.measure("full.row.diff", layer: "codec") { try projection.replacingDocument(state) }
        #expect(delta.changed.isEmpty && delta.removed.isEmpty && delta.repositioned.isEmpty)
        let data = try JSONEncoder().encode(snapshot.document)
        let json = try await r.measure("cold.document.json.decode", layer: "codec") {
            try JSONDecoder().decode(VocabularyDocument.self, from: data)
        }
        #expect(json == snapshot.document)
    }

    /// Remaining large-library paths share the same generated seed and public commands as
    /// the original inventory, without spending another run on unchanged review navigation.
    private func runRemaining(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        r.visibleEntries = { f.store.entries.count }
        try await r.measure("corpus.load.first", layer: "model") { await f.store.load() }
        try #require(f.store.isLoaded && f.store.errorMessage == nil && f.store.entries.count == r.entries)
        try await browse(f, r)
        let original = try f.entry(53)
        var edited = original; edited.senses[0].note += " A remaining-path edit."
        try #require(try await r.measure("editor.save.note") { await f.store.update(edited, basedOn: original) })
        try await organization(f, r)
        let merge = try f.entry(57)
        try #require(await f.store.mergeSenses(entryID: merge.id, source: merge.senses[0].id, target: merge.senses[1].id))
        try #require(try await r.measure("sense.merge.undo") { await f.store.undoLastSenseMerge() } != nil)
        let batch = (0..<50).map { VocabularyEntryInput(expression: "remaining-batch-\($0)", meaning: "Synthetic batch meaning") }
        let imported = try await r.measure("entry.import.50") { try await f.store.addEntries(batch) }
        try #require(imported.addedEntries == 50)
        let repeated = try await r.measure("entry.import.50.again") { try await f.store.addEntries(batch) }
        try #require(repeated.addedEntries == 0 && repeated.addedSenses == 50)
        try #require(try await r.measure("tag.remove.global") { await f.store.removeTag("group-3") })
        try await automation(f, r)
        try await exports(f, r)
        try await storageStages(f, r)
    }

    /// A failed test envelope must not force another run of unchanged multi-minute writes.
    /// This checkpoint rebuilds unrelated state from the same validated generator, then tests
    /// the CLI retry and remaining destinations on its own fresh notebook. Reports label it.
    private func runTail(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        r.visibleEntries = { f.store.entries.count }
        await f.store.load()
        try #require(f.store.isLoaded && f.store.errorMessage == nil && f.store.entries.count == r.entries)
        try await automation(f, r)
        try await review(f, r)
        try await exports(f, r)
        try await storageStages(f, r)
    }

    private func run(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder, focused: Bool) async throws {
        r.visibleEntries = { f.store.entries.count }
        try await r.measure("corpus.load.first", layer: "model") { await f.store.load() }
        try #require(f.store.isLoaded && f.store.errorMessage == nil && f.store.entries.count == r.entries)
        try await r.measure("corpus.load.cached", layer: "model") { await f.store.load() }
        try await browse(f, r)
        try await mutations(f, r, focused: focused)
        if !focused {
            try await organization(f, r)
            try await automation(f, r)
            try await review(f, r)
            try await exports(f, r)
        }
        try await storageStages(f, r)
    }

    private func browse(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        let cache = VocabularyBrowserCache()
        let entries = try await r.measure("browse.list.first", layer: "projection") {
            let entries = cache.entries(store: f.store, language: nil, tag: "", newestFirst: true)
            return cache.listRows(entries: cache.matching(entries, query: ""), expanded: [])
        }
        #expect(entries.count == r.entries)
        let cached = try await r.measure("browse.list.cached", layer: "projection") {
            cache.listRows(entries: cache.entries(store: f.store, language: nil, tag: "", newestFirst: true), expanded: [])
        }
        #expect(cached.count == entries.count)
        let expanded = try await r.measure("browse.expand.one", layer: "projection") {
            cache.listRows(entries: f.store.entries, expanded: [VocabularyBenchmarkFixture.id(1_000_050)])
        }
        #expect(expanded.count == r.entries + 2)
        let language = try await r.measure("browse.filter.language", layer: "projection") {
            cache.entries(store: f.store, language: .french, tag: "", newestFirst: true)
        }
        #expect(language.count == r.entries / 5)
        let tagged = try await r.measure("browse.filter.tag", layer: "projection") {
            cache.entries(store: f.store, language: nil, tag: "group-3", newestFirst: true)
        }
        #expect(tagged.count == r.entries / 20)
        let all = cache.entries(store: f.store, language: nil, tag: "", newestFirst: true)
        let matches = try await r.measure("browse.literal.query", layer: "projection") { cache.matching(all, query: "word99") }
        #expect(!matches.isEmpty)
        let meanings = try await r.measure("browse.meanings.first", layer: "projection") {
            cache.meanings(store: f.store, entries: all, query: "", includeEmpty: true, languages: [.english])
        }
        #expect(meanings.count == f.store.semantics.nodes.count)
        let outline = try await r.measure("browse.category.outline", layer: "projection") {
            VocabularyClassificationProjection.outlineRows(axis: .content, classification: f.store.classification,
                items: meanings, entries: all, languages: [.english], showsUnexplored: true)
        }
        #expect(!outline.isEmpty)
        let unclassified = try await r.measure("browse.unclassified", layer: "projection") {
            cache.unclassified(store: f.store, entries: all, query: "")
        }
        #expect(!unclassified.isEmpty)
        var preparation = VocabularySearchPreparation()
        let prepared = try await r.measure("search.prepare.first", layer: "projection") {
            preparation.prepare(entries: all, semantics: f.store.semantics, revision: f.store.contentRevision)
        }
        #expect(prepared.documents.count == r.entries * 2)
        let result = try await r.measure("search.keyword.query", layer: "projection") {
            VocabularySearchPolicy.results(documents: prepared.documents, meanings: prepared.meanings, query: "word99")
        }
        #expect(!result.isEmpty)
        // Retaining the published result models real copy-on-write ownership during a refresh.
        var edited = all
        edited[50].senses[0].note += " A benchmark edit."
        let revision = UUID()
        let refreshed = try await r.measure("search.prepare.one.receipt", layer: "projection") {
            preparation.prepare(entries: edited, semantics: f.store.semantics, revision: revision,
                entryChange: .init(baseRevision: f.store.contentRevision, revision: revision, entryID: edited[50].id))
        }
        #expect(refreshed.documents.count == prepared.documents.count)
        let worker = VocabularyGraphProjectionWorker()
        let key = VocabularyGraphProjectionKey(revision: f.store.contentRevision, language: nil, tag: "", query: "",
            expanded: [], isMeaningGraph: true, kind: nil, includeEmpty: true, languages: [.english], showsUnexplored: false)
        let graph = try await r.measure("graph.taxonomy.first", layer: "projection") {
            try await worker.project(key: key, entries: all, semantics: f.store.semantics, classification: f.store.classification)
        }
        #expect(!graph.snapshot.nodes.isEmpty)
        let repeated = try await r.measure("graph.taxonomy.cached", layer: "projection") {
            try await worker.project(key: key, entries: all, semantics: f.store.semantics, classification: f.store.classification)
        }
        #expect(graph.identity == repeated.identity)
        let entryGraph = try await r.measure("graph.entries.first", layer: "projection") {
            VocabularyGraphProjection.make(entries: all, expanded: [all[50].id], query: "")
        }
        #expect(!entryGraph.nodes.isEmpty)
    }

    private func mutations(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder, focused: Bool) async throws {
        let store = f.store
        for (name, withExample) in [("favorite.translation.first", false), ("favorite.context.first", true),
                                     ("favorite.translation.repeat", false), ("favorite.context.repeat", true)] {
            let capture = VocabularyBenchmarkFixture.capture("benchmark-\(name)", example: withExample)
            var search = VocabularySearchPreparation()
            let previous = search.prepare(entries: store.entries, semantics: store.semantics, revision: store.contentRevision)
            let browser = VocabularyBrowserCache()
            _ = browser.entries(store: store, language: nil, tag: "", newestFirst: true)
            try await r.measure(name) { await store.save(capture) }
            try #require(store.errorMessage == nil && store.contains(capture))
            if name == "favorite.context.first" {
                let next = try await r.measure("search.prepare.after.favorite", layer: "projection") {
                    search.prepare(entries: store.entries, semantics: store.semantics, revision: store.contentRevision,
                        entryChange: store.searchEntryChange)
                }
                #expect(next.documents.count == previous.documents.count + 1)
                let rows = try await r.measure("browse.list.after.favorite", layer: "projection") {
                    let entries = browser.entries(store: store, language: nil, tag: "", newestFirst: true)
                    return browser.listRows(entries: entries, expanded: [])
                }
                #expect(rows.count == store.entries.count)
            }
        }
        let existing = try f.entry(52)
        var append = VocabularyBenchmarkFixture.capture(existing.expression, example: true)
        append.senseID = existing.senses[0].id
        try await r.measure("favorite.context.existing") { await store.save(append) }
        try #require(store.errorMessage == nil && store.contains(append))
        if !focused {
            try await r.measure("favorite.context.remove") { await store.remove(append) }
            try #require(store.errorMessage == nil && !store.contains(append))
        }
        let before = try f.entry(53)
        var edited = before; edited.senses[0].note += " An edited note."
        let saved = try await r.measure("editor.save.note") { await store.update(edited, basedOn: before) }
        try #require(saved && store.errorMessage == nil)
        let meaningBefore = try f.entry(54)
        var meaningEdited = meaningBefore; meaningEdited.senses[0].meaning += " An edited translation."
        try #require(try await r.measure("editor.save.translation") { await store.update(meaningEdited, basedOn: meaningBefore) })
        if !focused {
            let created = try await r.measure("sense.create") {
                try await store.addEntries([.init(expression: existing.expression, language: existing.language,
                    kind: existing.kind, meaning: "An explicitly authored additional meaning")])
            }
            try #require(created.addedSenses == 1)
            let merge = try f.entry(57)
            try #require(try await r.measure("sense.merge") {
                await store.mergeSenses(entryID: merge.id, source: merge.senses[0].id, target: merge.senses[1].id)
            })
            let undone = try await r.measure("sense.merge.undo") { await store.undoLastSenseMerge() }
            try #require(undone != nil)
        }
        for (index, name) in [(58, "sense.remove.mapped"), (r.entries - 2, "sense.remove.unmapped")] {
            let entry = try f.entry(index)
            var search = VocabularySearchPreparation()
            let previous = search.prepare(entries: store.entries, semantics: store.semantics, revision: store.contentRevision)
            let browser = VocabularyBrowserCache()
            _ = browser.entries(store: store, language: nil, tag: "", newestFirst: true)
            let removed = try await r.measure(name) { await store.removeSense(entryID: entry.id, senseID: entry.senses[0].id) }
            try #require(removed && store.readIndex.entriesByID[entry.id]?.senses.count == 1)
            if name == "sense.remove.mapped" {
                let next = try await r.measure("search.prepare.after.remove", layer: "projection") {
                    search.prepare(entries: store.entries, semantics: store.semantics, revision: store.contentRevision,
                        entryChange: store.searchEntryChange)
                }
                #expect(next.documents.count == previous.documents.count - 1)
                let rows = try await r.measure("browse.list.after.remove", layer: "projection") {
                    let entries = browser.entries(store: store, language: nil, tag: "", newestFirst: true)
                    return browser.listRows(entries: entries, expanded: [])
                }
                #expect(rows.count == store.entries.count)
            }
        }
        let reviewed = try f.entry(55)
        let previousRevision = store.currentRevision
        let removedReviewed = try await r.measure("sense.remove.enrolled") {
            await store.removeSense(entryID: reviewed.id, senseID: reviewed.senses[0].id)
        }
        try r.outcome("sense.remove.enrolled", succeeded: removedReviewed, message: store.errorMessage)
        try #require(removedReviewed, "Enrolled Note source deletion must succeed after the data-layer correction")
        if !removedReviewed {
            // Measurement continues only after verifying the rejection published no mutation.
            // The report retains its error and labels this duration as a rejected request.
            let retained = try f.entry(55)
            #expect(store.currentRevision == previousRevision && retained == reviewed)
            let persisted = try f.repository.snapshot().document.entries.first { $0.id == reviewed.id }
            #expect(persisted == reviewed)
            store.errorMessage = nil
            // A failed SQLite writer may retire its checked cache. Warm the same read-only
            // state outside the next timer, so failure recovery is not charged to another command.
            let warm = await store.executeCLI(.init(command: .status))
            try #require(warm.ok)
        }
        if focused { return }
        let removeEntry = try f.entry(59)
        try #require(try await r.measure("entry.remove") { await store.remove(id: removeEntry.id) })
        let one = try await r.measure("entry.create.manual") {
            try await store.addEntries([.init(expression: "manual-benchmark", meaning: "Synthetic manual meaning")])
        }
        try #require(one.addedEntries == 1)
        let batch = (0..<50).map { VocabularyEntryInput(expression: "batch-benchmark-\($0)", meaning: "Synthetic imported meaning") }
        let imported = try await r.measure("entry.import.50") { try await store.addEntries(batch) }
        try #require(imported.addedEntries == 50)
        let sensesBeforeAgain = store.entries.reduce(0) { $0 + $1.senses.count }
        let duplicate = try await r.measure("entry.import.50.again") { try await store.addEntries(batch) }
        #expect(duplicate.addedEntries == 0 && duplicate.addedSenses == 50)
        #expect(store.entries.reduce(0) { $0 + $1.senses.count } == sensesBeforeAgain + 50)
        try #require(try await r.measure("tag.remove.global") { await store.removeTag("group-3") })
        try #require(store.errorMessage == nil)
        let image = try await r.measure("image.prepare") { try await store.prepareImage(VocabularyImageTestFixture.png()) }
        let imageBefore = try f.entry(61)
        var imageEdited = imageBefore
        imageEdited.senses[0].content = [.init(content: .image(image.reference, caption: "Synthetic image"))]
        try #require(try await r.measure("image.attach.save") {
            await store.update(imageEdited, basedOn: imageBefore, importedImages: [image.reference.filename: image.data])
        })
        let bytes = try await r.measure("image.read") { await store.image(image.reference) }
        #expect(bytes == image.data)
    }

    private func automation(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        let entry = try f.entry(65)
        let requests: [(String, CLIRequest)] = [
            ("cli.status", .init(command: .status)),
            ("cli.list.page", .init(command: .list, limit: 50)),
            ("cli.list.query", .init(command: .list, query: "word99", limit: 50)),
            ("cli.entry.read", .init(command: .get, entryID: entry.id)),
            ("cli.sense.read", .init(command: .sense, senseID: entry.senses[0].id)),
            ("cli.entries.read25", .init(command: .readMany,
                readSelection: .init(kind: .entries, ids: Array(f.store.entries.prefix(25).map(\.id)))))
        ]
        for (name, request) in requests {
            let result = try await r.measure(name, layer: "store-command") { await f.store.executeCLI(request) }
            try #require(result.ok)
        }
        let inputs: [[String: Any]] = (0..<50).map { index in
            ["expression": "cli-benchmark-\(index)", "senses": [["meaning": "Synthetic captured meaning"]]]
        }
        let batch: [String: Any] = ["version": 2, "idempotencyKey": "benchmark-\(r.entries)-\(r.trial)",
            "operations": [["capture": ["defaults": ["language": "en"], "entries": inputs]]]]
        let request = CLIRequest(command: .apply,
            batch: try JSONDecoder().decode(CLIBatch.self, from: JSONSerialization.data(withJSONObject: batch)), compactReceipt: true)
        let result = try await r.measure("cli.capture50", layer: "store-command") { await f.store.executeCLI(request) }
        try #require(result.ok)
        // A real CLI retry creates a fresh transport envelope while retaining its durable
        // batch idempotency key. Reusing a 30-second envelope after a long save tests expiry.
        var retry = request
        retry.id = UUID(); retry.expiresAt = Date().addingTimeInterval(30)
        let repeated = try await r.measure("cli.capture50.idempotent", layer: "store-command") { await f.store.executeCLI(retry) }
        try #require(repeated.ok)
    }

    private func organization(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        let store = f.store
        var before = store.semantics, edited = before
        edited.nodes[0].definition += " A shared semantic edit."
        try #require(try await r.measure("meaning.edit.shared") { await store.updateSemantics(edited, basedOn: before) })
        before = store.semantics; edited = before
        let date = Date()
        let added = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Benchmark new meaning", language: .english)],
            definition: "A synthetic new semantic node", createdAt: date, updatedAt: date)
        edited.nodes.append(added)
        try #require(try await r.measure("meaning.create") { await store.updateSemantics(edited, basedOn: before) })
        before = store.semantics; edited = before
        edited.mappings.append(.init(nodeID: added.id, senseID: try f.entry(62).senses[0].id))
        try #require(try await r.measure("meaning.associate") { await store.updateSemantics(edited, basedOn: before) })
        var categoryBefore = store.classification, categoryEdited = categoryBefore
        categoryEdited.memberships.append(.init(id: UUID(), nodeID: added.id,
            categoryID: VocabularyBenchmarkFixture.id(5_000_000)))
        try #require(try await r.measure("meaning.categorize") {
            await store.updateClassification(categoryEdited, basedOn: categoryBefore)
        })
        categoryBefore = store.classification; categoryEdited = categoryBefore
        let categoryIndex = try #require(categoryEdited.categories.firstIndex { $0.id == VocabularyBenchmarkFixture.id(5_000_000) })
        categoryEdited.categories[categoryIndex].definition += " A benchmark category edit."
        try #require(try await r.measure("category.edit") {
            await store.updateClassification(categoryEdited, basedOn: categoryBefore)
        })
        before = store.semantics; edited = before
        edited.nodes.removeAll { $0.id == added.id }; edited.mappings.removeAll { $0.nodeID == added.id }
        try #require(try await r.measure("meaning.remove") { await store.updateSemantics(edited, basedOn: before) })
        try #require(store.errorMessage == nil)
    }

    private func review(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        let session = f.review
        let hiddenEntry = try f.entry(66)
        let hiddenSelection = VocabularySelection(entryID: hiddenEntry.id, senseID: hiddenEntry.senses[0].id)
        let hiddenFailure = try await r.measure("review.enroll.one.hidden", layer: "model") {
            await session.enrollFromCorpus(hiddenSelection)
        }
        try #require(hiddenFailure == nil)
        try await r.measure("review.open.first", layer: "model") { session.open(selection: nil); await session.waitForIdle() }
        try #require(session.content != nil && session.message == nil)
        let count = try #require(session.content?.statistics.exercises)
        try await r.measure("review.open.repeat", layer: "model") {
            session.close(); session.open(selection: nil); await session.waitForIdle()
        }
        try #require(session.content?.statistics.exercises == count)
        let selection = try f.entry(63).senses[0].id
        let target = VocabularySelection(entryID: VocabularyBenchmarkFixture.id(1_000_063), senseID: selection)
        let failure = try await r.measure("review.enroll.one", layer: "model") {
            let error = await session.enrollFromCorpus(target)
            await session.waitForIdle(); return error
        }
        try #require(failure == nil)
        let noteModel = try #require(session.content?.noteCards.values.first { $0.note.senseID == target.senseID })
        session.editNote(noteModel)
        var noteDraft = try #require(session.noteDraft)
        noteDraft.note.exampleID = try #require(f.entry(63).senses[0].examples.last).id
        try await r.measure("review.note.edit.and.refresh", layer: "model") {
            session.saveNote(noteDraft); await session.waitForIdle()
        }
        try #require(session.message == nil && session.noteDraft == nil)
        #expect(session.content?.noteCards.values.first { $0.note.id == noteModel.note.id }?.note.exampleID == noteDraft.note.exampleID)
        session.editNoteType()
        var typeDraft = try #require(session.noteTypeDraft)
        typeDraft.type.templates[0].back += "<p>Benchmark shared template</p>"
        try await r.measure("review.type.edit.shared.and.refresh", layer: "model") {
            session.saveNoteType(typeDraft); await session.waitForIdle()
        }
        try #require(session.message == nil && session.noteTypeDraft == nil, "\(session.message ?? "The type draft did not close")")
        #expect(session.content?.defaultNoteType.revision == (typeDraft.expected?.revision ?? 0) + 1)
        let participation = try await r.measure("review.participation", layer: "model") {
            try await session.inspectParticipation(target)
        }
        #expect(participation.status == .active)
        let filtered = try await r.measure("review.content.search", layer: "model") {
            session.showContent(); session.browsing.search = "word1"; return session.contentSelections.count
        }
        #expect(filtered > 0)
        session.browsing.search = ""
        try await r.measure("review.practice.start", layer: "model") {
            session.start(selection: target); await session.waitForIdle()
        }
        try #require(session.practice != nil)
        try await r.measure("review.answer.reveal", layer: "model") { session.reveal() }
        try await r.measure("review.rate.and.refresh", layer: "model") { session.rate(.good); await session.waitForIdle() }
        let undo = try #require(session.latestUndo)
        try await r.measure("review.rating.undo.and.refresh", layer: "model") { session.undo(undo); await session.waitForIdle() }
        var content = try #require(session.content)
        try await r.measure("review.pause.and.refresh", layer: "model") {
            session.setStatus(.paused, selection: target, basedOn: content); await session.waitForIdle()
        }
        content = try #require(session.content)
        #expect(content.review.groups[target.senseID]?.status == .paused)
        try await r.measure("review.resume.and.refresh", layer: "model") {
            session.setStatus(.active, selection: target, basedOn: content); await session.waitForIdle()
        }
        content = try #require(session.content)
        try await r.measure("review.withdraw.and.refresh", layer: "model") {
            session.setStatus(.withdrawn, selection: target, basedOn: content); await session.waitForIdle()
        }
        try #require(session.content?.review.groups[target.senseID]?.status == .withdrawn)
        try await r.measure("review.navigation.resume", layer: "model") {
            session.suspend(); session.resume(); await session.waitForIdle()
        }
        session.suspend()
        try await r.measure("progress.open.first", layer: "model") { f.progress.setActive(true); await f.progress.waitForIdle() }
        if case .loaded = f.progress.state {} else { Issue.record("Progress did not load") }
        try await r.measure("progress.open.repeat", layer: "model") {
            f.progress.setActive(false); f.progress.setActive(true); await f.progress.waitForIdle()
        }
        try await r.measure("progress.reload", layer: "model") { f.progress.reload(); await f.progress.waitForIdle() }
        if case .loaded = f.progress.state {} else { Issue.record("Progress did not reload") }
        f.progress.setActive(false)
    }

    private func exports(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        let selections = f.store.entries.prefix(25).flatMap { entry in
            entry.senses.map { VocabularySelection(entryID: entry.id, senseID: $0.id) }
        }
        let package = try await r.measure("export.selected.prepare") {
            try await f.store.prepareExport(selections: selections, configuration: .init(format: .csv))
        }
        #expect(package.senseCount == selections.count)
        try await r.measure("export.selected.write") {
            try await f.store.writeExport(package, to: f.directory.appendingPathComponent("selection.csv"))
        }
        let backup = f.directory.appendingPathComponent("synthetic-backup.json")
        try await r.measure("backup.full.write") { await f.store.backup(to: backup) }
        try #require(f.store.errorMessage == nil && FileManager.default.fileExists(atPath: backup.path))
        try await r.measure("backup.full.restore") { await f.store.restore(from: backup) }
        try #require(f.store.errorMessage == nil)
    }

    /// These windows isolate the capture planner, engine transaction and UI read-index delta.
    /// They are separate invocations, so their medians explain cost rather than being added to
    /// reconstruct a different timed operation. Both old and new snapshots remain retained.
    private func storageStages(_ f: VocabularyBenchmarkFixture, _ r: VocabularyBenchmarkRecorder) async throws {
        let archive = VocabularyArchive(url: f.repository.databaseURL, mediaDirectoryURL: f.repository.mediaDirectoryURL)
        let baseline = try await archive.load()
        let capture = VocabularyBenchmarkFixture.capture("benchmark-stage-capture", example: true)
        let entry = try await r.measure("favorite.stage.plan", layer: "policy") {
            try VocabularyPolicy.entryForSave(capture, in: baseline.document, now: Date())
        }
        let saved = try await r.measure("favorite.stage.transaction", layer: "engine") {
            try await archive.perform(basedOn: baseline.scope.map(LingroveNotebookVersion.init)) { isolated in
                try isolated.persistence().saveNotebookEntry(entry, basedOn: isolated.transactionBaseline())
            }
        }
        let beforeIndex = f.store.readIndex
        let updatedIndex = try await r.measure("favorite.stage.readindex", layer: "projection") {
            var updated = beforeIndex
            updated.apply(.init(baseRevision: baseline.revision, entryID: entry.id, entry: entry))
            return updated
        }
        #expect(updatedIndex.entriesByID[entry.id] != nil && beforeIndex.entriesByID[entry.id] == nil)
        let removedEntry = try f.entry(64)
        let removed = try await r.measure("sense.remove.stage.transaction", layer: "engine") {
            try await archive.perform(basedOn: .init(saved)) { isolated in
                try isolated.persistence().removeNotebookSense(removedEntry.senses[0].id, from: removedEntry.id,
                    basedOn: saved)
            }
        }
        #expect(removed.document.entries.first { $0.id == removedEntry.id }?.senses.count == 1)
        await archive.shutdown()
    }
}
