import CoreGraphics
import Foundation

/// Graph identity follows durable notebook identities. A label or position can change without
/// turning a sense into another learning item; the graph never invents semantic relationships.
nonisolated enum VocabularyGraphNodeID: Hashable, Sendable {
    case headword(UUID)
    case sense(VocabularySelection)
    case meaning(UUID)
    case category(UUID)
    case axis(VocabularyCategory.Axis)

    var rootID: UUID {
        switch self {
        case .headword(let id): id
        case .sense(let selection): selection.entryID
        case .meaning(let id): id
        case .category(let id): id
        case .axis(let axis):
            axis == .content
                ? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                : UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        }
    }
    var selection: VocabularySelection? {
        if case .sense(let value) = self { return value }
        return nil
    }
    var categoryID: UUID? {
        if case .category(let id) = self { return id }
        return nil
    }
}

nonisolated struct VocabularyGraphNode: Equatable, Sendable, Identifiable {
    let id: VocabularyGraphNodeID
    let label: String
    var meaningKind: VocabularyMeaningNode.Kind?
    var axis: VocabularyCategory.Axis?
    var depth: Int = 0
    var itemCount: Int = 0
    var isUnexplored: Bool = false
    var hasChildren: Bool = false
    var isExpanded: Bool = false
}

nonisolated struct VocabularyGraphEdge: Equatable, Sendable {
    enum Kind: String, Sendable {
        case ownership
        case taxonomy
        case expressesContent
        case realizesFunction
        case narrower
        case opposite
        case related
    }
    let source: VocabularyGraphNodeID
    let target: VocabularyGraphNodeID
    var kind: Kind = .ownership
    var isUnexplored: Bool = false
}

/// A small, immutable rendering projection. Rich text, images, AX handles and model sessions
/// remain in the notebook detail view rather than entering the simulation or each frame.
/// When `isMeaningGraph` is true, `treePositions` supplies deterministic hierarchical coordinates
/// so the semantic taxonomy renders as a stable left-to-right tree rather than a drifting force cloud.
nonisolated struct VocabularyGraphSnapshot: Equatable, Sendable {
    var nodes: [VocabularyGraphNode] = []
    var edges: [VocabularyGraphEdge] = []
    var headwordCount = 0
    var matches: Set<VocabularyGraphNodeID> = []
    var searchQuery = ""
    var isMeaningGraph = false
    var treePositions: [VocabularyGraphNodeID: CGPoint] = [:]
}

/// Appearance and forces are notebook preferences, independent of stored learning content.
/// Validation also protects the numeric solver from damaged defaults and non-finite values.
nonisolated struct VocabularyGraphSettings: Codable, Equatable, Sendable {
    enum Labels: String, Codable, CaseIterable, Sendable { case automatic, all, focused }
    var nodeSize: Double = 17
    var linkWidth: Double = 1
    var labels: Labels = .automatic
    var center: Double = 0.008
    var repulsion: Double = 320
    var linkStrength: Double = 0.14
    var linkDistance: Double = 105

    var normalized: Self {
        var result = self
        result.nodeSize = Self.bound(nodeSize, to: 8...28, fallback: 17)
        result.linkWidth = Self.bound(linkWidth, to: 0.5...3, fallback: 1)
        result.center = Self.bound(center, to: 0...0.08, fallback: 0.008)
        result.repulsion = Self.bound(repulsion, to: 10...1200, fallback: 320)
        result.linkStrength = Self.bound(linkStrength, to: 0...0.7, fallback: 0.14)
        result.linkDistance = Self.bound(linkDistance, to: 60...240, fallback: 105)
        return result
    }

    private static func bound(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// Camera math stays separate from node coordinates, so panning and zooming never heat the
/// physics engine. NSView converts its events to these world coordinates before node dragging.
nonisolated struct VocabularyGraphCamera: Equatable, Sendable {
    var scale: CGFloat = 1
    var offset = CGPoint.zero

    func screen(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.x + point.x * scale, y: size.height / 2 + offset.y + point.y * scale)
    }
    func world(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2 - offset.x) / scale, y: (point.y - size.height / 2 - offset.y) / scale)
    }
    mutating func zoom(by factor: CGFloat, at point: CGPoint, in size: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = world(point, in: size)
        scale = min(4, max(0.15, scale * factor))
        offset = CGPoint(x: point.x - size.width / 2 - anchor.x * scale, y: point.y - size.height / 2 - anchor.y * scale)
    }
    mutating func fit(_ positions: [CGPoint], in size: CGSize) {
        guard let first = positions.first, size.width > 0, size.height > 0 else { return }
        var rect = CGRect(origin: first, size: .zero)
        for point in positions.dropFirst() {
            rect = rect.union(CGRect(x: point.x, y: point.y, width: 0.01, height: 0.01))
        }
        scale = min(1.8, max(0.15, min((size.width - 150) / max(100, rect.width),
                                     (size.height - 130) / max(100, rect.height))))
        offset = CGPoint(x: -rect.midX * scale, y: -rect.midY * scale)
    }
}

nonisolated struct VocabularyGraphFrame: Equatable, Sendable {
    var positions: [VocabularyGraphNodeID: CGPoint] = [:]
    var isRunning = false
}
