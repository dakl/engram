import Foundation
import Testing
@testable import EngramCore

/// Builds an undirected edge with the `a < b` (by uuidString) convention.
private func makeEdge(_ x: UUID, _ y: UUID, weight: Double = 1) -> GraphEdge {
    let lo = x.uuidString <= y.uuidString ? x : y
    let hi = x.uuidString <= y.uuidString ? y : x
    return GraphEdge(a: lo, b: hi, weight: weight, kinds: [.semantic])
}

/// Every node in a fully-connected `group` linked to every other.
private func clique(_ group: [Memory]) -> [GraphEdge] {
    var edges: [GraphEdge] = []
    for i in 0..<group.count {
        for j in (i + 1)..<group.count {
            edges.append(makeEdge(group[i].id, group[j].id))
        }
    }
    return edges
}

private func isFinite(_ point: SIMD2<Double>) -> Bool {
    point.x.isFinite && point.y.isFinite
}

private func distance(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>) -> Double {
    let delta = lhs - rhs
    return (delta.x * delta.x + delta.y * delta.y).squareRoot()
}

/// Steps a layout until it reports settled, with a safety cap so a non-settling
/// bug fails the test rather than hanging.
private func settle(_ layout: inout ForceDirectedLayout, safetyCap: Int = 10_000) {
    var iterations = 0
    while !layout.isSettled && iterations < safetyCap {
        layout.step()
        iterations += 1
    }
}

/// Two triangles connected to each other: the layout must settle within
/// `maxSteps` and produce only finite coordinates.
@Test func layoutSettlesWithFinitePositions() {
    let groupA = (0..<3).map { Memory(content: "a\($0)") }
    let groupB = (0..<3).map { Memory(content: "b\($0)") }
    let nodes = (groupA + groupB).map { GraphNode(memory: $0) }
    var edges = clique(groupA) + clique(groupB)
    edges.append(makeEdge(groupA[0].id, groupB[0].id))

    var layout = ForceDirectedLayout(graph: MemoryGraph(nodes: nodes, edges: edges))
    settle(&layout)

    #expect(layout.isSettled)
    for (_, point) in layout.positions() {
        #expect(isFinite(point))
    }
}

/// Same graph, same number of steps ⇒ byte-identical positions (no RNG).
@Test func layoutIsDeterministic() {
    let memories = (0..<8).map { Memory(content: "m\($0)") }
    let nodes = memories.map { GraphNode(memory: $0) }
    let edges = clique(memories)
    let graph = MemoryGraph(nodes: nodes, edges: edges)

    var first = ForceDirectedLayout(graph: graph)
    var second = ForceDirectedLayout(graph: graph)
    for _ in 0..<50 {
        first.step()
        second.step()
    }

    let firstPositions = first.positions()
    let secondPositions = second.positions()
    #expect(firstPositions.count == secondPositions.count)
    for (id, point) in firstPositions {
        #expect(secondPositions[id] == point)
    }
}

/// Two internally-connected clusters with no inter-cluster edges: after settling,
/// nodes within a cluster sit closer together than nodes across clusters.
@Test func connectedNodesEndUpCloserThanDisconnected() {
    let groupA = (0..<4).map { Memory(content: "a\($0)") }
    let groupB = (0..<4).map { Memory(content: "b\($0)") }
    let nodes = (groupA + groupB).map { GraphNode(memory: $0) }
    let edges = clique(groupA) + clique(groupB)

    var layout = ForceDirectedLayout(graph: MemoryGraph(nodes: nodes, edges: edges))
    settle(&layout)
    let positions = layout.positions()

    func meanPairwiseDistance(within group: [Memory]) -> Double {
        var total = 0.0
        var count = 0
        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                total += distance(positions[group[i].id]!, positions[group[j].id]!)
                count += 1
            }
        }
        return total / Double(count)
    }

    var crossTotal = 0.0
    var crossCount = 0
    for memoryA in groupA {
        for memoryB in groupB {
            crossTotal += distance(positions[memoryA.id]!, positions[memoryB.id]!)
            crossCount += 1
        }
    }

    let intraMean = (meanPairwiseDistance(within: groupA) + meanPairwiseDistance(within: groupB)) / 2
    let interMean = crossTotal / Double(crossCount)
    #expect(intraMean < interMean)
}

/// With no edges at all, community cohesion alone must still group same-community
/// nodes closer than cross-community ones (isolating the centroid force).
@Test func communityCohesionGroupsNodesWithoutEdges() {
    let groupA = (0..<4).map { Memory(content: "a\($0)") }
    let groupB = (0..<4).map { Memory(content: "b\($0)") }
    let nodes = (groupA + groupB).map { GraphNode(memory: $0) }
    var communities: [UUID: Int] = [:]
    for memory in groupA { communities[memory.id] = 0 }
    for memory in groupB { communities[memory.id] = 1 }

    var layout = ForceDirectedLayout(
        graph: MemoryGraph(nodes: nodes, edges: []),
        communities: communities,
        config: .init(communityStrength: 0.1)
    )
    settle(&layout)
    let positions = layout.positions()

    func meanPairwiseDistance(within group: [Memory]) -> Double {
        var total = 0.0
        var count = 0
        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                total += distance(positions[group[i].id]!, positions[group[j].id]!)
                count += 1
            }
        }
        return total / Double(count)
    }

    var crossTotal = 0.0
    var crossCount = 0
    for memoryA in groupA {
        for memoryB in groupB {
            crossTotal += distance(positions[memoryA.id]!, positions[memoryB.id]!)
            crossCount += 1
        }
    }

    let intraMean = (meanPairwiseDistance(within: groupA) + meanPairwiseDistance(within: groupB)) / 2
    let interMean = crossTotal / Double(crossCount)
    #expect(intraMean < interMean)
}

/// Turning on group separation pushes the two communities' centroids farther
/// apart than cohesion alone does.
@Test func groupSeparationSpreadsCommunitiesApart() {
    let groupA = (0..<4).map { Memory(content: "a\($0)") }
    let groupB = (0..<4).map { Memory(content: "b\($0)") }
    let nodes = (groupA + groupB).map { GraphNode(memory: $0) }
    var communities: [UUID: Int] = [:]
    for memory in groupA { communities[memory.id] = 0 }
    for memory in groupB { communities[memory.id] = 1 }
    let graph = MemoryGraph(nodes: nodes, edges: [])

    func centroidGap(separation: Double) -> Double {
        var layout = ForceDirectedLayout(
            graph: graph, communities: communities,
            config: .init(communityStrength: 0.1, groupSeparation: separation)
        )
        settle(&layout)
        let positions = layout.positions()
        func centroid(_ group: [Memory]) -> SIMD2<Double> {
            let sum = group.reduce(SIMD2<Double>(0, 0)) { $0 + positions[$1.id]! }
            return sum / Double(group.count)
        }
        return distance(centroid(groupA), centroid(groupB))
    }

    #expect(centroidGap(separation: 4000) > centroidGap(separation: 0))
}

/// An empty graph must not crash and yields no positions.
@Test func emptyGraphDoesNotCrash() {
    var layout = ForceDirectedLayout(graph: MemoryGraph(nodes: [], edges: []))
    settle(&layout)
    #expect(layout.positions().isEmpty)
}

/// A single isolated node must not crash and stays finite.
@Test func singleNodeDoesNotCrash() {
    let memory = Memory(content: "lonely")
    let layout0 = MemoryGraph(nodes: [GraphNode(memory: memory)], edges: [])
    var layout = ForceDirectedLayout(graph: layout0)
    settle(&layout)

    let positions = layout.positions()
    #expect(positions.count == 1)
    #expect(isFinite(positions[memory.id]!))
}
