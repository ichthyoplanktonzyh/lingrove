import CoreGraphics
import Foundation
import Testing
@testable import Cotabby

struct VocabularyGraphTests {
    @Test func projectionKeepsSensesDistinctAndEdgesExplicit() {
        let entry = fixture()
        let overview = VocabularyGraphProjection.make(entries: [entry], expanded: [], query: "")
        #expect(overview.nodes.map(\.id) == [.headword(entry.id)])
        #expect(overview.edges.isEmpty)
        let open = VocabularyGraphProjection.make(entries: [entry], expanded: [entry.id], query: "")
        #expect(open.nodes.count == 3 && open.edges.count == 2)
        #expect(open.edges.allSatisfy { $0.source == .headword(entry.id) })
        #expect(Set(open.nodes.map(\.id)).count == 3)
        let search = VocabularyGraphProjection.make(entries: [entry], expanded: [], query: "河岸")
        #expect(search.nodes.count == 3)
        let wordSearch = VocabularyGraphProjection.make(entries: [entry], expanded: [], query: "bank")
        #expect(wordSearch.nodes.count == 1)
    }

    @Test func cameraZoomKeepsPointerAnchoredAndFitHandlesSingleNode() {
        let viewport = CGSize(width: 900, height: 600), pointer = CGPoint(x: 123, y: 233)
        var camera = VocabularyGraphCamera()
        let before = camera.world(pointer, in: viewport)
        camera.zoom(by: 2, at: pointer, in: viewport)
        #expect(camera.world(pointer, in: viewport) == before)
        camera.fit([CGPoint(x: 400, y: -50)], in: viewport)
        let point = camera.screen(CGPoint(x: 400, y: -50), in: viewport)
        #expect(abs(point.x - 450) < 0.1 && abs(point.y - 300) < 0.1)
        camera.zoom(by: .nan, at: pointer, in: viewport)
        #expect(camera.scale.isFinite)
    }

    @Test func corruptSettingsCannotFeedNonfiniteForces() {
        var settings = VocabularyGraphSettings()
        settings.nodeSize = .infinity; settings.linkDistance = -400
        settings.center = .nan; settings.linkStrength = 20
        let safe = settings.normalized
        #expect(safe.nodeSize == 17 && safe.linkDistance == 60)
        #expect(safe.center == 0.008 && safe.linkStrength == 0.7)
    }

    @Test func solverPreservesIdentityAcrossExpansionDragsNeighborsAndCools() async throws {
        let worker = VocabularyGraphLayoutWorker(), entry = fixture()
        let overview = VocabularyGraphProjection.make(entries: [entry], expanded: [], query: "")
        let initial = try #require(await worker.configure(overview, settings: .init(), epoch: 1))
        let open = VocabularyGraphProjection.make(entries: [entry], expanded: [entry.id], query: "")
        let expanded = try #require(await worker.configure(open, settings: .init(), epoch: 2))
        #expect(initial.positions[.headword(entry.id)] == expanded.positions[.headword(entry.id)])
        let child = VocabularyGraphNodeID.sense(.init(entryID: entry.id, senseID: entry.senses[0].id))
        let target = CGPoint(x: 400, y: 100)
        var frame = expanded
        for _ in 0..<20 { frame = try #require(await worker.advance(epoch: 2, pinned: .headword(entry.id), position: target)) }
        #expect(frame.positions[.headword(entry.id)] == target)
        #expect(frame.positions[child] != expanded.positions[child])
        for _ in 0..<240 { frame = try #require(await worker.advance(epoch: 2, pinned: nil, position: nil)) }
        #expect(!frame.isRunning)
        #expect(frame.positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let settled = frame.positions
        frame = try #require(await worker.advance(epoch: 2, pinned: nil, position: nil))
        #expect(frame.positions == settled)
        await worker.suspend(epoch: 3, finalNode: .headword(entry.id), finalPosition: target)
        let reopened = try #require(await worker.configure(open, settings: .init(), epoch: 4))
        #expect(reopened.positions[.headword(entry.id)] == target)
        #expect(await worker.configure(overview, settings: .init(), epoch: 1) == nil)
        #expect(await worker.advance(epoch: 1, pinned: nil, position: nil) == nil)
    }

    @Test func largeGraphProducesFiniteReleaseFrames() async throws {
        let worker = VocabularyGraphLayoutWorker()
        let nodes = (0..<1000).map { VocabularyGraphNode(id: .headword(UUID()), label: "word \($0)") }
        let graph = VocabularyGraphSnapshot(nodes: nodes, headwordCount: nodes.count)
        let clock = ContinuousClock(), start = clock.now
        var frame = try #require(await worker.configure(graph, settings: .init(), epoch: 1))
        for _ in 0..<20 { frame = try #require(await worker.advance(epoch: 1, pinned: nil, position: nil)) }
        #expect(frame.positions.count == 1000)
        #expect(frame.positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        print("Graph 1000-node configure + 20 steps: \(start.duration(to: clock.now))")
        let empty = try #require(await worker.configure(.init(), settings: .init(), epoch: 2))
        #expect(empty.positions.isEmpty && !empty.isRunning)
    }

    private func fixture() -> VocabularyEntry {
        let now = Date()
        return .init(id: UUID(), expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            senses: [.init(id: UUID(), meaning: "银行", createdAt: now, updatedAt: now),
                     .init(id: UUID(), meaning: "河岸", createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
    }
}
