import Foundation

/// Which signal contributed to an edge between two memories (ADR 0007).
public enum EdgeKind: Sendable, Hashable {
    case semantic
    case sharedTag
    case sharedSource
}

/// A memory positioned in the graph. `id` mirrors the memory's id so nodes are
/// `Identifiable` for SwiftUI/diffing without a separate identity.
public struct GraphNode: Identifiable, Sendable {
    public let id: UUID
    public let memory: Memory

    public init(memory: Memory) {
        self.id = memory.id
        self.memory = memory
    }
}

/// An undirected, deduped edge. By convention `a < b` by `uuidString`, so a pair
/// has exactly one edge regardless of the direction it was discovered from.
public struct GraphEdge: Sendable {
    public let a: UUID
    public let b: UUID
    public let weight: Double
    public let kinds: Set<EdgeKind>

    public init(a: UUID, b: UUID, weight: Double, kinds: Set<EdgeKind>) {
        self.a = a
        self.b = b
        self.weight = weight
        self.kinds = kinds
    }
}

/// A built graph: the nodes plus the surviving blended edges.
public struct MemoryGraph: Sendable {
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]

    public init(nodes: [GraphNode], edges: [GraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

/// Tunable weights and pruning thresholds for edge-blending (ADR 0007).
public struct GraphConfig: Sendable {
    /// α — weight of the semantic (vector-neighbour) signal.
    public var semanticWeight: Double
    /// β — weight of the shared-tag (idf-weighted) signal.
    public var tagWeight: Double
    /// γ — weight of the shared-source signal.
    public var sourceWeight: Double
    /// k — max edges kept per node after pruning.
    public var neighborsPerNode: Int
    /// Drop semantic neighbours with cosine distance above this.
    public var distanceCutoff: Double
    /// Drop blended edges below this weight.
    public var edgeFloor: Double

    public init(
        semanticWeight: Double = 0.5,
        tagWeight: Double = 0.3,
        sourceWeight: Double = 0.2,
        neighborsPerNode: Int = 6,
        distanceCutoff: Double = 0.9,
        edgeFloor: Double = 0.05
    ) {
        self.semanticWeight = semanticWeight
        self.tagWeight = tagWeight
        self.sourceWeight = sourceWeight
        self.neighborsPerNode = neighborsPerNode
        self.distanceCutoff = distanceCutoff
        self.edgeFloor = edgeFloor
    }

    public static let `default` = GraphConfig()
}

/// Pure, DB-free edge construction for the memory graph (ADR 0007).
public enum MemoryGraphBuilder {
    /// An unordered pair of memory ids, ordered by `uuidString` so `(a, b)` and
    /// `(b, a)` hash and compare identically.
    private struct Pair: Hashable {
        let a: UUID
        let b: UUID

        init(_ x: UUID, _ y: UUID) {
            if x.uuidString <= y.uuidString {
                a = x
                b = y
            } else {
                a = y
                b = x
            }
        }
    }

    /// Accumulator for one pair's blended weight and the kinds that fired.
    private struct Accumulator {
        var weight: Double = 0
        var kinds: Set<EdgeKind> = []
    }

    /// Blends semantic (from `neighbors`), shared-tag (idf-weighted) and
    /// shared-source signals into a pruned, deduped undirected edge set.
    public static func blend(
        memories: [Memory],
        neighbors: [UUID: [(id: UUID, distance: Double)]],
        config: GraphConfig = .default
    ) -> [GraphEdge] {
        let memoryCount = memories.count
        guard memoryCount > 1 else { return [] }

        // idf: a tag in every memory ≈ 0, a rare tag scores high.
        var documentFrequency: [String: Int] = [:]
        var sourceCount: [String: Int] = [:]
        for memory in memories {
            for tag in Set(memory.tags) {
                documentFrequency[tag, default: 0] += 1
            }
            if let source = memory.source {
                sourceCount[source, default: 0] += 1
            }
        }
        var idf: [String: Double] = [:]
        for (tag, frequency) in documentFrequency {
            idf[tag] = log((1.0 + Double(memoryCount)) / (1.0 + Double(frequency)))
        }

        var accumulators: [Pair: Accumulator] = [:]

        // Semantic: treat a→b symmetrically, gating on the distance cutoff.
        for memory in memories {
            guard let hits = neighbors[memory.id] else { continue }
            for hit in hits where hit.distance <= config.distanceCutoff {
                guard hit.id != memory.id else { continue }
                let similarity = max(0, 1 - hit.distance / 2)
                add(
                    config.semanticWeight * similarity,
                    kind: .semantic,
                    to: Pair(memory.id, hit.id),
                    into: &accumulators
                )
            }
        }

        // Shared tags: inverted index tag→members, then score each co-member pair.
        var membersByTag: [String: [UUID]] = [:]
        for memory in memories {
            for tag in Set(memory.tags) {
                membersByTag[tag, default: []].append(memory.id)
            }
        }
        // Sum idf over shared tags per pair, then add once with the .sharedTag mark.
        var tagScoreByPair: [Pair: Double] = [:]
        for (tag, members) in membersByTag where members.count > 1 {
            let weight = idf[tag] ?? 0
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    tagScoreByPair[Pair(members[i], members[j]), default: 0] += weight
                }
            }
        }
        for (pair, tagScore) in tagScoreByPair {
            add(config.tagWeight * tagScore, kind: .sharedTag, to: pair, into: &accumulators)
        }

        // Shared source: pairs with the same non-nil source, down-weighting big sources.
        var membersBySource: [String: [UUID]] = [:]
        for memory in memories {
            if let source = memory.source {
                membersBySource[source, default: []].append(memory.id)
            }
        }
        for (source, members) in membersBySource where members.count > 1 {
            let score = 1.0 / log(2.0 + Double(sourceCount[source] ?? members.count))
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    add(
                        config.sourceWeight * score,
                        kind: .sharedSource,
                        to: Pair(members[i], members[j]),
                        into: &accumulators
                    )
                }
            }
        }

        let candidates: [GraphEdge] = accumulators.compactMap { pair, accumulator in
            guard accumulator.weight >= config.edgeFloor else { return nil }
            return GraphEdge(a: pair.a, b: pair.b, weight: accumulator.weight, kinds: accumulator.kinds)
        }

        let pruned = prune(candidates, neighborsPerNode: config.neighborsPerNode)
        return pruned.sorted { ($0.a.uuidString, $0.b.uuidString) < ($1.a.uuidString, $1.b.uuidString) }
    }

    private static func add(
        _ weight: Double,
        kind: EdgeKind,
        to pair: Pair,
        into accumulators: inout [Pair: Accumulator]
    ) {
        var accumulator = accumulators[pair] ?? Accumulator()
        accumulator.weight += weight
        accumulator.kinds.insert(kind)
        accumulators[pair] = accumulator
    }

    /// Keep an edge if it ranks in the top-k by weight for EITHER endpoint
    /// (union rule), so the graph stays sparse without starving any node.
    private static func prune(_ edges: [GraphEdge], neighborsPerNode k: Int) -> [GraphEdge] {
        guard k > 0 else { return [] }

        var indicesByNode: [UUID: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            indicesByNode[edge.a, default: []].append(index)
            indicesByNode[edge.b, default: []].append(index)
        }

        var survivors = Set<Int>()
        for (_, indices) in indicesByNode {
            let topK = indices.sorted { edges[$0].weight > edges[$1].weight }.prefix(k)
            survivors.formUnion(topK)
        }

        return survivors.sorted().map { edges[$0] }
    }
}
