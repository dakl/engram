import Foundation
import Testing
@testable import EngramCore

/// Builds an undirected edge with the `a < b` (by uuidString) convention.
private func makeEdge(_ x: UUID, _ y: UUID, weight: Double) -> GraphEdge {
    let lo = x.uuidString <= y.uuidString ? x : y
    let hi = x.uuidString <= y.uuidString ? y : x
    return GraphEdge(a: lo, b: hi, weight: weight, kinds: [.semantic])
}

/// Collects every leaf cluster (single-memory, no children) under `cluster`.
private func leaves(of cluster: Cluster) -> [Cluster] {
    if cluster.children.isEmpty {
        return [cluster]
    }
    return cluster.children.flatMap(leaves)
}

/// Two dense groups with strong intra-group edges and no inter-group edges
/// must surface as two top-level communities.
@Test func twoObviousClustersBecomeTwoTopLevelCommunities() {
    let groupA = (0..<3).map { Memory(content: "a\($0)", tags: ["alpha"]) }
    let groupB = (0..<3).map { Memory(content: "b\($0)", tags: ["beta"]) }
    let nodes = (groupA + groupB).map { GraphNode(memory: $0) }

    var edges: [GraphEdge] = []
    for group in [groupA, groupB] {
        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                edges.append(makeEdge(group[i].id, group[j].id, weight: 10))
            }
        }
    }

    let root = Communities.louvain(MemoryGraph(nodes: nodes, edges: edges))

    #expect(root.children.count == 2)
    let childMemberSets = root.children.map { Set($0.memberIDs) }
    #expect(childMemberSets.contains(Set(groupA.map(\.id))))
    #expect(childMemberSets.contains(Set(groupB.map(\.id))))
}

/// The hierarchy must bottom out at single-memory leaves that cover every node
/// id exactly once.
@Test func hierarchyReachesMemoryLeaves() {
    let groupA = (0..<3).map { Memory(content: "a\($0)", tags: ["alpha"]) }
    let groupB = (0..<3).map { Memory(content: "b\($0)", tags: ["beta"]) }
    let lonely = Memory(content: "isolated", tags: ["solo"])
    let memories = groupA + groupB + [lonely]
    let nodes = memories.map { GraphNode(memory: $0) }

    var edges: [GraphEdge] = []
    for group in [groupA, groupB] {
        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                edges.append(makeEdge(group[i].id, group[j].id, weight: 5))
            }
        }
    }

    let root = Communities.louvain(MemoryGraph(nodes: nodes, edges: edges))

    let leafClusters = leaves(of: root)
    #expect(leafClusters.allSatisfy { $0.memberIDs.count == 1 && $0.children.isEmpty })
    let coveredIDs = leafClusters.map { $0.memberIDs[0] }
    #expect(Set(coveredIDs) == Set(memories.map(\.id)))
    #expect(coveredIDs.count == memories.count)  // each exactly once
}

/// Same input ⇒ identical partition and labels on every run.
@Test func louvainIsDeterministic() {
    let groupA = (0..<4).map { Memory(content: "a\($0)", tags: ["alpha", "shared"]) }
    let groupB = (0..<4).map { Memory(content: "b\($0)", tags: ["beta", "shared"]) }
    let nodes = (groupA + groupB).map { GraphNode(memory: $0) }

    var edges: [GraphEdge] = []
    for group in [groupA, groupB] {
        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                edges.append(makeEdge(group[i].id, group[j].id, weight: 8))
            }
        }
    }
    // A couple of weak cross-links to make the optimisation non-trivial.
    edges.append(makeEdge(groupA[0].id, groupB[0].id, weight: 0.1))
    let graph = MemoryGraph(nodes: nodes, edges: edges)

    let first = Communities.louvain(graph)
    let second = Communities.louvain(graph)

    #expect(structureSignature(first) == structureSignature(second))
}

/// Stringifies a cluster tree (labels + ordered member partition) for comparison.
private func structureSignature(_ cluster: Cluster) -> String {
    let members = cluster.memberIDs.map(\.uuidString).joined(separator: ",")
    let childSignatures = cluster.children.map(structureSignature).joined(separator: "|")
    return "[\(cluster.label):\(members):(\(childSignatures))]"
}
