import Foundation
import LingroveNotebookEngine
import SQLite3
import Testing
@testable import Lingrove

/// Binary cache tests use small unit vectors and private SQLite files, so cache correctness
/// and atomicity need no downloaded model or installed notebook.
struct VocabularySearchVectorCacheTests {
    @Test @MainActor func indexRetriesFailedCachePruningWithoutLoadingAModel() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        let documents = Array(VocabularySearchPolicy.documents(entries: fixture.entries, semantics: fixture.semantics).prefix(2))
        let vector = [Float(1)] + Array(repeating: Float(0), count: VocabularySearchCatalog.dimensions - 1)
        let cache = VocabularySearchVectorCache(url: f.url, model: VocabularySearchCatalog.identity, dimensions: VocabularySearchCatalog.dimensions)
        _ = try cache.save(Dictionary(uniqueKeysWithValues: documents.map { ($0.fingerprint, vector) }))
        let core = try f.core(); defer { try? core.close() }
        try core.executeScript(sql: """
            CREATE TRIGGER fail_pruning BEFORE DELETE ON search_vectors BEGIN SELECT RAISE(ABORT,'Pruning failed'); END;
            """, errorContext: "Inject pruning failure")
        let index = VocabularySearchIndex(cacheURL: f.url), missingModel = f.directory.appendingPathComponent("missing.gguf")
        try await index.reconcile(Array(documents.suffix(1)), modelURL: missingModel) { _, _ in }
        #expect(try cache.load().count == 2)
        try core.executeScript(sql: "DROP TRIGGER fail_pruning;", errorContext: "Retire pruning failure")
        try await index.reconcile(Array(documents.suffix(1)), modelURL: missingModel) { _, _ in }
        let reloaded = try cache.load()
        #expect(reloaded.count == 1 && reloaded[documents[0].fingerprint] == nil)
        try core.close()
        await index.unload(removingCache: true)
    }

    @Test func roundTripDeltaPruningAndUnchangedRowsRemainExact() throws {
        let f = Fixture(); defer { f.cleanUp() }
        let cache = f.cache()
        #expect(try cache.load().isEmpty)
        let a = key("a"), b = key("b"), c = key("c")
        let vectors: [String: [Float]] = [a: [1, 0, 0, 0], b: [0, 1, 0, 0]]
        #expect(try cache.save(vectors) == 2)
        let core = try f.core(); defer { try? core.close() }
        try core.executeScript(sql: """
            CREATE TRIGGER protect_cached_vector BEFORE UPDATE ON search_vectors
            WHEN OLD.fingerprint='\(b)' BEGIN SELECT RAISE(ABORT,'Unrelated vector rewritten'); END;
            CREATE TRIGGER protect_cached_delete BEFORE DELETE ON search_vectors
            WHEN OLD.fingerprint='\(b)' BEGIN SELECT RAISE(ABORT,'Unrelated vector removed'); END;
            CREATE TRIGGER protect_cached_insert BEFORE INSERT ON search_vectors
            WHEN NEW.fingerprint='\(b)' BEGIN SELECT RAISE(ABORT,'Unrelated vector replaced'); END;
            """, errorContext: "Protect unchanged cache row")
        #expect(try cache.save([b: vectors[b]!, c: [0, 0, 1, 0]]) == 2)
        #expect(try f.cache().load() == [b: vectors[b]!, c: [0, 0, 1, 0]])
        #expect(try cache.save([b: vectors[b]!, c: [0, 0, 1, 0]]) == 0)
    }

    @Test func anUnreadableCacheCanBeRebuiltWithoutASecondRestore() throws {
        let f = Fixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        try Data("A damaged derived cache".utf8).write(to: f.url)
        let cache = f.cache(), a = key("a")
        #expect(throws: (any Error).self) { try cache.load() }
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
        _ = try cache.save([a: [1, 0, 0, 0]])
        #expect(try f.cache().load() == [a: [1, 0, 0, 0]])
    }

    @Test func lateFailureRollsBackPruningAndRemainsRetryable() throws {
        let f = Fixture(); defer { f.cleanUp() }
        let cache = f.cache(), a = key("a"), b = key("b")
        _ = try cache.save([a: [1, 0, 0, 0]])
        let core = try f.core(); defer { try? core.close() }
        try core.executeScript(sql: """
            CREATE TRIGGER fail_cache_insert BEFORE INSERT ON search_vectors BEGIN SELECT RAISE(ABORT,'Cache write fault'); END;
            """, errorContext: "Inject cache failure")
        #expect(throws: (any Error).self) { try cache.save([b: [0, 1, 0, 0]]) }
        #expect(try f.cache().load() == [a: [1, 0, 0, 0]])
        try core.executeScript(sql: "DROP TRIGGER fail_cache_insert;", errorContext: "Retire cache failure")
        _ = try cache.save([b: [0, 1, 0, 0]])
        #expect(try f.cache().load() == [b: [0, 1, 0, 0]])
    }

    @Test func corruptRowsModelsAndCapacityRemainBoundedAndRebuildable() throws {
        let f = Fixture(); defer { f.cleanUp() }
        let a = key("a"), b = key("b"), c = key("c"), cache = f.cache(maximumRows: 2)
        _ = try cache.save([a: [1, 0, 0, 0], b: [0, 1, 0, 0], c: [0, 0, 1, 0]])
        #expect(try f.cache(maximumRows: 2).load().count == 2)
        let core = try f.core(); defer { try? core.close() }
        try core.execute(sql: "UPDATE search_vectors SET vector=? WHERE fingerprint=?", values: [.blob(Data([0, 1])), .text(a)])
        #expect(try f.cache(maximumRows: 2).load() == [b: [0, 1, 0, 0]])
        #expect(try f.cache(model: "another model").load().isEmpty)
        try core.close()
        cache.remove()
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
        #expect(try cache.load().isEmpty)
        _ = try cache.save([c: [0, 0, 1, 0]])
        #expect(try f.cache().load() == [c: [0, 0, 1, 0]])
    }

    private func key(_ letter: Character) -> String { String(repeating: String(letter), count: 64) }

    /// One test owns the path and all short-lived connections; no global runtime/cache discovery.
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-vector-cache-" + UUID().uuidString)
        var url: URL { directory.appendingPathComponent("vectors.sqlite") }
        func cache(model: String = "fixture", maximumRows: Int = 49_152) -> VocabularySearchVectorCache {
            .init(url: url, model: model, dimensions: 4, maximumRows: maximumRows)
        }
        func core() throws -> DatabaseCore { try .init(databaseURL: url, mediaDirectoryURL: directory) { _ in nil } }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
