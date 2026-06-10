import Foundation

/// Pure, deterministic spring-electrical (force-directed) graph layout (ADR 0009).
///
/// Hand-rolled to avoid the Grape dependency. This type holds only the layout
/// math — no UI — so it lives in `EngramCore` and is unit-testable. Seeding is
/// deterministic (no RNG): identical input graphs always produce identical
/// layouts. The app's rendering layer (G3b) consumes `positions()`.
public struct ForceDirectedLayout: Sendable {
    /// Tunable physics parameters. Defaults are sane for graphs of hundreds of nodes.
    public struct Config: Sendable {
        /// Ideal rest length of an edge; springs pull endpoints toward this distance.
        public var springLength: Double
        /// Attraction strength along edges (Hooke's law coefficient).
        public var springStrength: Double
        /// Inverse-square node-node repulsion coefficient (Coulomb-like).
        public var repulsion: Double
        /// Mild pull of every node toward the origin, keeping the graph centered.
        public var centerStrength: Double
        /// Pull of each node toward its community's centroid, so same-community
        /// nodes coalesce into a spatial neighbourhood. `0` disables it (default,
        /// so behaviour is unchanged when no communities are supplied).
        public var communityStrength: Double
        /// How much an edge's weight shortens its rest length, in `[0, 1)`: the
        /// effective rest is `springLength * (1 − weightRestScaling * weight)`
        /// (floored), so stronger relationships settle closer. `0` keeps every
        /// edge at `springLength` (default — unchanged behaviour).
        public var weightRestScaling: Double
        /// Inverse-distance repulsion between whole community centroids, so groups
        /// spread into separate territories rather than overlapping. `0` disables
        /// it (default). Pairs with `communityStrength`, which keeps each group tight.
        public var groupSeparation: Double
        /// Velocity retained per step (0…1); lower values cool the system faster.
        public var damping: Double
        /// Once `alpha` drops below this, the layout is considered settled.
        public var settleThreshold: Double
        /// Hard cap on iterations; settles unconditionally once reached.
        public var maxSteps: Int

        public init(
            springLength: Double = 60,
            springStrength: Double = 0.1,
            repulsion: Double = 2000,
            centerStrength: Double = 0.02,
            communityStrength: Double = 0,
            weightRestScaling: Double = 0,
            groupSeparation: Double = 0,
            damping: Double = 0.85,
            settleThreshold: Double = 0.01,
            maxSteps: Int = 500
        ) {
            self.springLength = springLength
            self.springStrength = springStrength
            self.repulsion = repulsion
            self.centerStrength = centerStrength
            self.communityStrength = communityStrength
            self.weightRestScaling = weightRestScaling
            self.groupSeparation = groupSeparation
            self.damping = damping
            self.settleThreshold = settleThreshold
            self.maxSteps = maxSteps
        }

        public static let `default` = Config()
    }

    /// Smallest separation used in force math, guarding against div-by-zero and
    /// runaway forces when two nodes coincide.
    private static let minimumDistance: Double = 1e-3

    /// Golden angle (radians) — successive spiral seeds are spread by this to avoid
    /// alignment artifacts.
    private static let goldenAngle: Double = 2.399963

    private let config: Config

    /// Node ids, sorted by `uuidString`, fixing each node's index for the run so
    /// seeding and per-step iteration are order-independent of the input array.
    private let nodeIDs: [UUID]
    /// For each node index, the indices of its edge neighbours and the edge weight.
    private let adjacency: [[(neighbor: Int, weight: Double)]]
    /// Community id per node index, or `nil` for nodes in no community. Drives the
    /// optional centroid-cohesion force.
    private let communityByIndex: [Int?]

    private var positionByIndex: [SIMD2<Double>]
    private var velocityByIndex: [SIMD2<Double>]

    /// Simulated-annealing temperature: scales applied force and decays per step.
    private var alpha: Double = 1.0
    private var stepCount: Int = 0

    /// - Parameter communities: node id → community id. Nodes absent from the map
    ///   feel no cohesion force. Empty (default) reproduces the plain layout.
    public init(graph: MemoryGraph, communities: [UUID: Int] = [:], config: Config = .default) {
        self.config = config

        let sortedIDs = graph.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString }
        self.nodeIDs = sortedIDs

        var indexByID: [UUID: Int] = [:]
        for (index, id) in sortedIDs.enumerated() {
            indexByID[id] = index
        }

        var adjacency: [[(neighbor: Int, weight: Double)]] = Array(repeating: [], count: sortedIDs.count)
        for edge in graph.edges {
            guard let i = indexByID[edge.a], let j = indexByID[edge.b], i != j else { continue }
            adjacency[i].append((neighbor: j, weight: edge.weight))
            adjacency[j].append((neighbor: i, weight: edge.weight))
        }
        self.adjacency = adjacency
        self.communityByIndex = sortedIDs.map { communities[$0] }

        // Deterministic golden-angle spiral seed: radius ∝ √index spreads nodes
        // evenly over a disc; the golden angle avoids spokes/rings overlapping.
        self.positionByIndex = sortedIDs.indices.map { index in
            let radius = sqrt(Double(index))
            let angle = Double(index) * ForceDirectedLayout.goldenAngle
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }
        self.velocityByIndex = Array(repeating: SIMD2<Double>(0, 0), count: sortedIDs.count)
    }

    /// `true` once `alpha` has cooled below the threshold or the step cap is hit.
    public var isSettled: Bool {
        alpha < config.settleThreshold || stepCount >= config.maxSteps
    }

    /// Current node positions keyed by node id.
    public func positions() -> [UUID: SIMD2<Double>] {
        var result: [UUID: SIMD2<Double>] = [:]
        for (index, id) in nodeIDs.enumerated() {
            result[id] = positionByIndex[index]
        }
        return result
    }

    /// Advance the simulation one iteration. No-op once settled.
    public mutating func step() {
        guard !isSettled else { return }
        let nodeCount = positionByIndex.count

        var forces = Array(repeating: SIMD2<Double>(0, 0), count: nodeCount)

        // Repulsion: every unordered pair pushes apart with magnitude
        // repulsion / distance². O(n²), fine for hundreds of nodes.
        if nodeCount > 1 {
            for i in 0..<(nodeCount - 1) {
                for j in (i + 1)..<nodeCount {
                    let delta = positionByIndex[i] - positionByIndex[j]
                    let distance = max(length(delta), ForceDirectedLayout.minimumDistance)
                    let direction = delta / distance
                    let magnitude = config.repulsion / (distance * distance)
                    let push = direction * magnitude
                    forces[i] += push
                    forces[j] -= push
                }
            }
        }

        // Spring attraction: each edge pulls endpoints toward springLength.
        // Hooke's law: force ∝ (distance − rest), scaled by strength × weight.
        // Each undirected edge is stored twice (once per endpoint), so we apply
        // half the force here and rely on the mirror entry for the rest.
        for i in 0..<nodeCount {
            for (neighbor, weight) in adjacency[i] {
                let delta = positionByIndex[neighbor] - positionByIndex[i]
                let distance = max(length(delta), ForceDirectedLayout.minimumDistance)
                let direction = delta / distance
                // Stronger edges rest closer (floored so they never collapse).
                let restScale = max(1 - config.weightRestScaling * weight, 0.2)
                let restLength = config.springLength * restScale
                let displacement = distance - restLength
                let magnitude = config.springStrength * weight * displacement
                forces[i] += direction * (magnitude * 0.5)
            }
        }

        // Centering: a mild spring pulling each node toward the origin so a
        // disconnected graph cannot drift off to infinity.
        for i in 0..<nodeCount {
            forces[i] -= positionByIndex[i] * config.centerStrength
        }

        // Community forces: pull each node toward its community centroid
        // (cohesion → tight groups) and repel whole community centroids from each
        // other (separation → non-overlapping territories). Both need centroids,
        // so compute them once and skip the block when neither force is on.
        if config.communityStrength > 0 || config.groupSeparation > 0 {
            var sumByCommunity: [Int: SIMD2<Double>] = [:]
            var countByCommunity: [Int: Int] = [:]
            for i in 0..<nodeCount {
                guard let community = communityByIndex[i] else { continue }
                sumByCommunity[community, default: .zero] += positionByIndex[i]
                countByCommunity[community, default: 0] += 1
            }
            var centroidByCommunity: [Int: SIMD2<Double>] = [:]
            for (community, sum) in sumByCommunity {
                centroidByCommunity[community] = sum / Double(countByCommunity[community]!)
            }

            if config.communityStrength > 0 {
                for i in 0..<nodeCount {
                    guard let community = communityByIndex[i],
                          let centroid = centroidByCommunity[community] else { continue }
                    forces[i] += (centroid - positionByIndex[i]) * config.communityStrength
                }
            }

            // Inverse-square repulsion between centroids, applied to every member
            // of a group so the whole territory drifts away from its neighbours.
            if config.groupSeparation > 0, centroidByCommunity.count > 1 {
                let communities = Array(centroidByCommunity.keys)
                var pushByCommunity: [Int: SIMD2<Double>] = [:]
                for a in 0..<(communities.count - 1) {
                    for b in (a + 1)..<communities.count {
                        let ca = communities[a], cb = communities[b]
                        let delta = centroidByCommunity[ca]! - centroidByCommunity[cb]!
                        let distance = max(length(delta), ForceDirectedLayout.minimumDistance)
                        let push = (delta / distance) * (config.groupSeparation / (distance * distance))
                        pushByCommunity[ca, default: .zero] += push
                        pushByCommunity[cb, default: .zero] -= push
                    }
                }
                for i in 0..<nodeCount {
                    guard let community = communityByIndex[i],
                          let push = pushByCommunity[community] else { continue }
                    forces[i] += push
                }
            }
        }

        // Integrate: velocity gathers force scaled by the cooling alpha, is damped,
        // then moves the node.
        for i in 0..<nodeCount {
            velocityByIndex[i] = (velocityByIndex[i] + forces[i] * alpha) * config.damping
            positionByIndex[i] += velocityByIndex[i]
        }

        alpha *= 0.99
        stepCount += 1
    }

    /// Euclidean length of a 2D vector.
    private func length(_ vector: SIMD2<Double>) -> Double {
        (vector.x * vector.x + vector.y * vector.y).squareRoot()
    }
}
