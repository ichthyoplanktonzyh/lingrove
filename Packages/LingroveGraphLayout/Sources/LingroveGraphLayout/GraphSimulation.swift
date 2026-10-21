import ForceSimulation
import simd

/// A serially owned adapter over Grape's package-private particle buffers. The application
/// confines this object to one actor; copied SIMD arrays are the only values crossing it.
public final class GraphSimulation {
    public struct Parameters: Equatable, Sendable {
        public var center: Double
        public var repulsion: Double
        public var linkStrength: Double
        public var linkDistance: Double

        public init(center: Double, repulsion: Double, linkStrength: Double, linkDistance: Double) {
            self.center = center
            self.repulsion = repulsion
            self.linkStrength = linkStrength
            self.linkDistance = linkDistance
        }
    }

    public struct Snapshot: Sendable {
        public let positions: [SIMD2<Double>]
        public let velocities: [SIMD2<Double>]
        public let isRunning: Bool
    }

    private let simulation: Simulation2D<SealedForce2D>
    private var pinnedIndex: Int?

    /// Empty graphs stay in the app's value layer instead of entering upstream's spatial tree.
    public init(positions: [SIMD2<Double>], velocities: [SIMD2<Double>],
                edges: [SIMD2<Int>], parameters: Parameters) {
        precondition(!positions.isEmpty && positions.count == velocities.count)
        let field = SealedForce2D {
            Kinetics2D.ManyBodyForce(strength: -parameters.repulsion)
            Kinetics2D.LinkForce(stiffness: .constant(parameters.linkStrength),
                                 originalLength: .constant(parameters.linkDistance))
            Kinetics2D.PositionForce(direction: .x, targetOnDirection: .constant(0),
                                     strength: .constant(parameters.center))
            Kinetics2D.PositionForce(direction: .y, targetOnDirection: .constant(0),
                                     strength: .constant(parameters.center))
            Kinetics2D.CollideForce(radius: .constant(28))
        }
        simulation = Simulation(nodeCount: positions.count,
            links: edges.map { EdgeID(source: $0.x, target: $0.y) }, forceField: field,
            initialAlpha: 0.65, alphaMin: 0.003, alphaDecay: 0.035, velocityDecay: 0.65,
            position: positions, velocity: velocities)
    }

    public var snapshot: Snapshot {
        .init(positions: simulation.kinetics.position.asArray(),
              velocities: simulation.kinetics.velocity.asArray(),
              isRunning: simulation.kinetics.alpha >= simulation.kinetics.alphaMin)
    }

    /// Fixation follows the pointer during dragging; clearing it lets springs and repulsion
    /// act again. Resetting the pinned velocity prevents a stored impulse on release.
    public func step(pinned: Int?, at position: SIMD2<Double>?) -> Snapshot {
        if let previous = pinnedIndex, previous != pinned {
            simulation.kinetics.fixation[previous] = nil
            simulation.kinetics.velocity[previous] = .zero
            simulation.kinetics.alpha = max(simulation.kinetics.alpha, 0.3)
        }
        pinnedIndex = pinned
        if let pinned, let position, pinned >= 0, pinned < simulation.kinetics.validCount {
            simulation.kinetics.fixation[pinned] = position
            simulation.kinetics.velocity[pinned] = .zero
            simulation.kinetics.alpha = max(simulation.kinetics.alpha, 0.3)
        }
        simulation.tick()
        if let pinnedIndex { simulation.kinetics.velocity[pinnedIndex] = .zero }
        return snapshot
    }
}
