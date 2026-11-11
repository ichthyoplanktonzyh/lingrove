import CoreGraphics
import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

@MainActor
struct VocabularyGraphProjectionWorkerTests {
    @Test func unchangedRequestsAndInvisibleEditsPreserveCanvasIdentity() async throws {
        let worker = VocabularyGraphProjectionWorker()
        var fixture = VocabularySearchPolicyTests.influenceFixture()
        let revision = UUID()
        let key = key(revision)
        let first = try await worker.project(key: key, entries: fixture.entries, semantics: fixture.semantics, classification: nil)
        let repeated = try await worker.project(key: key, entries: fixture.entries, semantics: fixture.semantics, classification: nil)
        #expect(first.identity == repeated.identity && first.snapshot == repeated.snapshot)
        #expect(await worker.buildCount == 1)
        var entries = fixture.entries
        entries[0].senses[0].note = "Unrelated to empty-query graph geometry"
        fixture.entries = entries
        let edited = try await worker.project(key: self.key(UUID()), entries: fixture.entries, semantics: fixture.semantics, classification: nil)
        #expect(first.identity == edited.identity)
        fixture.semantics.nodes[0].labels[0].text = "A visible new title"
        let renamed = try await worker.project(key: self.key(UUID()), entries: fixture.entries, semantics: fixture.semantics, classification: nil)
        #expect(renamed.identity != first.identity)
        #expect(renamed.snapshot.nodes.contains { $0.label == "A visible new title" })
    }

    @Test func filtersExpansionAndCancellationFollowTheLatestRequest() async throws {
        let worker = VocabularyGraphProjectionWorker(), fixture = VocabularySearchPolicyTests.influenceFixture()
        let revision = UUID()
        let first = try await worker.project(key: key(revision), entries: fixture.entries, semantics: fixture.semantics, classification: nil)
        let expanded = key(revision, expanded: [fixture.semantics.nodes[0].id])
        let second = try await worker.project(key: expanded, entries: fixture.entries, semantics: fixture.semantics, classification: nil)
        #expect(second.snapshot.nodes.count > first.snapshot.nodes.count)
        let count = await worker.buildCount
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.project(key: self.key(UUID()), entries: [], semantics: nil, classification: nil)
        }
        do { _ = try await task.value; Issue.record("Cancelled projection published") } catch is CancellationError { }
        #expect(await worker.buildCount == count)
        let retained = try await worker.project(key: expanded, entries: fixture.entries, semantics: fixture.semantics, classification: nil)
        #expect(retained.identity == second.identity)
    }

    @Test func edgeCullingRetainsCrossingPathsAndDecorations() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(VocabularyGraphViewport.containsEdge(from: .init(x: -500, y: 300), to: .init(x: 1200, y: 300), viewport: viewport))
        #expect(VocabularyGraphViewport.containsEdge(from: .init(x: -120, y: 200), to: .init(x: -120, y: 400), viewport: viewport))
        #expect(!VocabularyGraphViewport.containsEdge(from: .init(x: 100, y: 2000), to: .init(x: 500, y: 2000), viewport: viewport))
    }

    private func key(_ revision: UUID, expanded: Set<UUID> = []) -> VocabularyGraphProjectionKey {
        .init(revision: revision, language: nil, tag: "", query: "", expanded: expanded,
            isMeaningGraph: true, kind: nil, includeEmpty: true, languages: [.english], showsUnexplored: false)
    }
}
