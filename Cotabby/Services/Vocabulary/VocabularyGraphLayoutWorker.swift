import CoreGraphics
import Foundation
import LingroveGraphLayout

/// One notebook window owns this actor. Grape's mutable native buffers never leave it: the
/// main actor receives copied positions and controls exactly when another physics step is needed.
actor VocabularyGraphLayoutWorker {
    private var simulation: GraphSimulation?
    private var ids: [VocabularyGraphNodeID] = []
    private var indices: [VocabularyGraphNodeID: Int] = [:]
    private var cached: [VocabularyGraphNodeID: SIMD2<Double>] = [:]
    private var epoch: UInt64 = 0
    private var graph = VocabularyGraphSnapshot()
    private var settings = VocabularyGraphSettings()

    func configure(_ graph: VocabularyGraphSnapshot, settings: VocabularyGraphSettings, epoch: UInt64) -> VocabularyGraphFrame? {
        guard epoch >= self.epoch else { return nil }
        self.epoch = epoch
        let settings = settings.normalized
        let forceChanged = self.settings.center != settings.center || self.settings.repulsion != settings.repulsion
            || self.settings.linkStrength != settings.linkStrength || self.settings.linkDistance != settings.linkDistance
        self.settings = settings
        let nextIDs = graph.nodes.map(\.id)
        let topologyChanged = nextIDs != ids || graph.edges != self.graph.edges
        self.graph = graph
        guard topologyChanged || forceChanged || simulation == nil else { return frame() }
        let previous = simulation?.snapshot
        var velocities: [VocabularyGraphNodeID: SIMD2<Double>] = [:]
        if let previous {
            for (index, id) in ids.enumerated() {
                cached[id] = previous.positions[index]
                velocities[id] = previous.velocities[index]
            }
        }
        ids = nextIDs
        indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        guard !ids.isEmpty else { simulation = nil; return .init() }
        var positions: [SIMD2<Double>] = []
        for (index, id) in ids.enumerated() {
            let angle = Double(index) * 2.399963229728653
            let radius = 60 * sqrt(Double(index + 1))
            let seed = SIMD2(cos(angle) * radius, sin(angle) * radius)
            if let old = cached[id] { positions.append(old) } else if id.selection != nil {
                let parent = cached[.headword(id.entryID)] ?? .zero
                positions.append(parent + SIMD2(cos(angle), sin(angle)) * settings.linkDistance)
            } else { positions.append(seed) }
        }
        let links = graph.edges.compactMap { edge -> SIMD2<Int>? in
            guard let source = indices[edge.source], let target = indices[edge.target] else { return nil }
            return SIMD2(source, target)
        }
        simulation = GraphSimulation(positions: positions, velocities: ids.map { velocities[$0] ?? .zero }, edges: links,
            parameters: .init(center: settings.center, repulsion: settings.repulsion,
                              linkStrength: settings.linkStrength, linkDistance: settings.linkDistance))
        // Keep filtered positions for stable return, but bound the window's ephemeral cache.
        if cached.count > max(4096, ids.count * 2) { cached = cached.filter { indices[$0.key] != nil } }
        return frame()
    }

    func advance(epoch: UInt64, pinned: VocabularyGraphNodeID?, position: CGPoint?) -> VocabularyGraphFrame? {
        guard epoch == self.epoch, let simulation else { return nil }
        let point = position.map { SIMD2(Double($0.x), Double($0.y)) }
        let snapshot = simulation.step(pinned: pinned.flatMap { indices[$0] }, at: point)
        return frame(snapshot)
    }

    /// A retained library window keeps its coordinate cache, not Grape's native buffers.
    /// Epoch ordering prevents a delayed close from releasing a newly reopened simulation.
    func suspend(epoch: UInt64, finalNode: VocabularyGraphNodeID? = nil, finalPosition: CGPoint? = nil) {
        guard epoch >= self.epoch else { return }
        self.epoch = epoch
        if let snapshot = simulation?.snapshot {
            for (index, id) in ids.enumerated() { cached[id] = snapshot.positions[index] }
        }
        if let finalNode, let finalPosition {
            cached[finalNode] = SIMD2(finalPosition.x, finalPosition.y)
        }
        if cached.count > 4096 {
            let retained = Set(ids.prefix(4096))
            cached = cached.filter { retained.contains($0.key) }
        }
        simulation = nil
        ids = []; indices = [:]; graph = .init()
    }

    private func frame(_ value: GraphSimulation.Snapshot? = nil) -> VocabularyGraphFrame {
        guard let snapshot = value ?? simulation?.snapshot else { return .init() }
        var positions: [VocabularyGraphNodeID: CGPoint] = [:]
        for (index, id) in ids.enumerated() {
            let point = snapshot.positions[index]
            // A corrupt solver result must not become invalid Core Graphics geometry.
            positions[id] = point.x.isFinite && point.y.isFinite
                ? CGPoint(x: point.x, y: point.y) : .zero
        }
        return .init(positions: positions, isRunning: snapshot.isRunning)
    }
}
