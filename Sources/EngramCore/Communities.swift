import Foundation

/// A node in the community hierarchy produced by Louvain (ADR 0007). A leaf wraps
/// a single memory; an internal node groups its members' sub-clusters as children.
public struct Cluster: Identifiable, Sendable {
    public let id: Int
    /// Most distinctive tag among members (count × idf), or "" if none shared.
    public let label: String
    /// Every memory id in this subtree.
    public let memberIDs: [UUID]
    /// Sub-clusters; empty for a memory leaf.
    public let children: [Cluster]

    public init(id: Int, label: String, memberIDs: [UUID], children: [Cluster]) {
        self.id = id
        self.label = label
        self.memberIDs = memberIDs
        self.children = children
    }
}

/// Deterministic Louvain community detection over a `MemoryGraph`.
public enum Communities {
    /// Below this modularity gain a candidate move is treated as no improvement,
    /// guarding against floating-point churn that would break determinism.
    private static let epsilon = 1e-9

    /// Deterministic Louvain (modularity maximisation). Multi-level passes form
    /// the hierarchy: root → top communities → sub-communities → memory leaves.
    public static func louvain(_ graph: MemoryGraph) -> Cluster {
        // Fixed iteration order: node ids sorted by uuidString. Index 0..<n is the
        // identity used throughout the algorithm so every run is byte-identical.
        let orderedIDs = graph.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let indexOfID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        let nodeCount = orderedIDs.count

        let idfByTag = computeIDF(graph)
        let tagsByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, Set($0.memory.tags)) })

        // Bottom layer: one leaf cluster per memory. `currentLevel[i]` is the
        // sub-cluster (built so far) carried by aggregated super-node `i`.
        var nextClusterID = 0
        var currentLevel: [Cluster] = orderedIDs.map { id in
            let leaf = Cluster(
                id: nextClusterID,
                label: distinctiveLabel(for: [id], tagsByID: tagsByID, idf: idfByTag),
                memberIDs: [id],
                children: []
            )
            nextClusterID += 1
            return leaf
        }

        // Aggregated weighted graph for the current level: self-loops hold collapsed
        // intra-community weight, neighbour entries hold summed inter-node weight.
        var weights = WeightedGraph(nodeCount: nodeCount)
        for edge in graph.edges {
            guard let i = indexOfID[edge.a], let j = indexOfID[edge.b] else { continue }
            weights.addEdge(i, j, edge.weight)
        }

        // Repeated level passes: partition the current graph, fold each community's
        // sub-clusters into a new parent cluster, then aggregate and recurse.
        while true {
            let communityOf = partition(weights)
            let groups = groupBySmallestMemberFirst(communityOf, nodeCount: weights.nodeCount)

            // No merging happened (every super-node is alone): the current level is
            // already as coarse as it gets, so stop and let it become the top layer.
            if groups.count == weights.nodeCount {
                break
            }

            var nextLevel: [Cluster] = []
            for group in groups {
                let children = group.map { currentLevel[$0] }
                let memberIDs = children.flatMap(\.memberIDs)
                let parent = Cluster(
                    id: nextClusterID,
                    label: distinctiveLabel(for: memberIDs, tagsByID: tagsByID, idf: idfByTag),
                    memberIDs: memberIDs,
                    children: children
                )
                nextClusterID += 1
                nextLevel.append(parent)
            }

            // Aggregate: collapse each community into a super-node, summing inter-
            // community weights into edges and intra-community weights into self-loops.
            weights = aggregate(weights, communityOf: communityOf, groups: groups)
            currentLevel = nextLevel
        }

        // Root groups the final (top-level) communities.
        let allIDs = currentLevel.flatMap(\.memberIDs)
        return Cluster(id: nextClusterID, label: "all", memberIDs: allIDs, children: currentLevel)
    }

    // MARK: - Weighted aggregated graph

    /// Symmetric weighted graph over `0..<nodeCount`. `selfLoop[i]` holds weight
    /// internal to a collapsed community; `neighbors[i]` are inter-node weights.
    private struct WeightedGraph {
        var nodeCount: Int
        /// `neighbors[i][j]` = weight between super-nodes i and j (i ≠ j), stored on both ends.
        var neighbors: [[Int: Double]]
        var selfLoop: [Double]
        /// Sum of all edge weights touching i (each non-self edge counted once here),
        /// i.e. the weighted degree `k_i` including 2× its self-loop.
        var degree: [Double]
        /// 2m — total weight (each undirected edge counted twice; self-loops twice).
        var totalWeight: Double

        init(nodeCount: Int) {
            self.nodeCount = nodeCount
            self.neighbors = Array(repeating: [:], count: nodeCount)
            self.selfLoop = Array(repeating: 0, count: nodeCount)
            self.degree = Array(repeating: 0, count: nodeCount)
            self.totalWeight = 0
        }

        mutating func addEdge(_ i: Int, _ j: Int, _ weight: Double) {
            if i == j {
                selfLoop[i] += weight
                degree[i] += 2 * weight
                totalWeight += 2 * weight
            } else {
                neighbors[i][j, default: 0] += weight
                neighbors[j][i, default: 0] += weight
                degree[i] += weight
                degree[j] += weight
                totalWeight += 2 * weight
            }
        }
    }

    // MARK: - One Louvain level pass

    /// Local-moving phase: each node starts alone, then repeatedly moves to the
    /// neighbouring community with the largest positive modularity gain. Returns
    /// the community label per super-node. Deterministic: fixed 0..<n order,
    /// lowest-community-id tie-break.
    private static func partition(_ graph: WeightedGraph) -> [Int] {
        let n = graph.nodeCount
        var community = Array(0..<n)
        // Total weighted degree of all nodes currently in each community.
        var communityDegree = graph.degree
        let twoM = graph.totalWeight
        guard twoM > 0 else { return community }

        var moved = true
        while moved {
            moved = false
            for node in 0..<n {
                let current = community[node]
                let nodeDegree = graph.degree[node]

                // Weight from `node` into each candidate community (its own + neighbours').
                var weightToCommunity: [Int: Double] = [:]
                for (neighbor, weight) in graph.neighbors[node] {
                    weightToCommunity[community[neighbor], default: 0] += weight
                }

                // Remove node from its community before scoring, so "staying" and
                // "moving" are compared on equal footing.
                communityDegree[current] -= nodeDegree

                // Modularity gain of joining community c (constant terms dropped):
                //   Δ = weightToC - (nodeDegree × Σdegree_in_c) / 2m
                // Pick the largest; ties go to the lowest community id for determinism.
                var bestCommunity = current
                var bestGain = (weightToCommunity[current] ?? 0)
                    - nodeDegree * communityDegree[current] / twoM
                let candidateIDs = ([current] + Array(weightToCommunity.keys)).sorted()
                for candidate in candidateIDs {
                    let gain = (weightToCommunity[candidate] ?? 0)
                        - nodeDegree * communityDegree[candidate] / twoM
                    if gain > bestGain + epsilon {
                        bestGain = gain
                        bestCommunity = candidate
                    }
                }

                communityDegree[bestCommunity] += nodeDegree
                if bestCommunity != current {
                    community[node] = bestCommunity
                    moved = true
                }
            }
        }
        return community
    }

    /// Groups super-node indices by community, each group sorted ascending, and the
    /// groups themselves ordered by their smallest member — a stable, RNG-free order.
    private static func groupBySmallestMemberFirst(_ community: [Int], nodeCount: Int) -> [[Int]] {
        var membersByCommunity: [Int: [Int]] = [:]
        for node in 0..<nodeCount {
            membersByCommunity[community[node], default: []].append(node)
        }
        return membersByCommunity.values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    /// Builds the next-level graph: one super-node per group, with summed inter-
    /// community weights as edges and summed intra-community weights as self-loops.
    private static func aggregate(
        _ graph: WeightedGraph,
        communityOf: [Int],
        groups: [[Int]]
    ) -> WeightedGraph {
        // Map old community label → new contiguous super-node index.
        var superIndexOfCommunity: [Int: Int] = [:]
        for (newIndex, group) in groups.enumerated() {
            superIndexOfCommunity[communityOf[group[0]]] = newIndex
        }

        var next = WeightedGraph(nodeCount: groups.count)
        // Accumulate each undirected edge once; iterate i<j over neighbour pairs.
        for i in 0..<graph.nodeCount {
            let si = superIndexOfCommunity[communityOf[i]]!
            // Carry forward the node's existing self-loop into its super-node.
            if graph.selfLoop[i] > 0 {
                next.addEdge(si, si, graph.selfLoop[i])
            }
            for (j, weight) in graph.neighbors[i] where j > i {
                let sj = superIndexOfCommunity[communityOf[j]]!
                next.addEdge(si, sj, weight)
            }
        }
        return next
    }

    // MARK: - Labelling

    /// idf over ALL graph nodes: a tag on everything scores ≈ 0, a rare tag high.
    private static func computeIDF(_ graph: MemoryGraph) -> [String: Double] {
        let total = graph.nodes.count
        var documentFrequency: [String: Int] = [:]
        for node in graph.nodes {
            for tag in Set(node.memory.tags) {
                documentFrequency[tag, default: 0] += 1
            }
        }
        var idf: [String: Double] = [:]
        for (tag, frequency) in documentFrequency {
            idf[tag] = log((1.0 + Double(total)) / (1.0 + Double(frequency)))
        }
        return idf
    }

    /// The top `limit` tags maximising `count_in_cluster × idf`, joined with " · ".
    /// Ties break alphabetically so the result is deterministic. "" when the
    /// members share no tags at all. `limit == 1` is the canonical cluster label;
    /// the Structure lens passes `limit: 2` for a slightly richer caption.
    static func distinctiveLabel(
        for memberIDs: [UUID],
        tagsByID: [UUID: Set<String>],
        idf: [String: Double],
        limit: Int = 1
    ) -> String {
        var countInCluster: [String: Int] = [:]
        for id in memberIDs {
            for tag in tagsByID[id] ?? [] {
                countInCluster[tag, default: 0] += 1
            }
        }
        guard !countInCluster.isEmpty else { return "" }

        // Rank by count×idf descending, tag ascending for a stable tie-break.
        let ranked = countInCluster.sorted { lhs, rhs in
            let lhsScore = Double(lhs.value) * (idf[lhs.key] ?? 0)
            let rhsScore = Double(rhs.value) * (idf[rhs.key] ?? 0)
            return lhsScore != rhsScore ? lhsScore > rhsScore : lhs.key < rhs.key
        }
        return ranked.prefix(max(limit, 1)).map(\.key).joined(separator: " · ")
    }
}
