import Foundation
import Testing
@testable import EngramCore

/// Empty semantic signal so a test can isolate the tag/source contribution.
private let noNeighbors: [UUID: [(id: UUID, distance: Double)]] = [:]

private func edge(_ edges: [GraphEdge], between x: UUID, and y: UUID) -> GraphEdge? {
    let lo = x.uuidString <= y.uuidString ? x : y
    let hi = x.uuidString <= y.uuidString ? y : x
    return edges.first { $0.a == lo && $0.b == hi }
}

@Test func idfDownWeightsPopularTags() {
    // "common" is on every memory (idf ≈ 0); "rare" is on just two.
    let common = "common"
    let rare = "rare"
    let popularA = Memory(content: "pa", tags: [common])
    let popularB = Memory(content: "pb", tags: [common])
    let rareA = Memory(content: "ra", tags: [common, rare])
    let rareB = Memory(content: "rb", tags: [common, rare])
    let filler = (0..<6).map { Memory(content: "f\($0)", tags: [common]) }
    let memories = [popularA, popularB, rareA, rareB] + filler

    let edges = MemoryGraphBuilder.blend(memories: memories, neighbors: noNeighbors)

    // popularA–popularB share only the common (low-idf) tag.
    let commonEdge = edge(edges, between: popularA.id, and: popularB.id)
    // rareA–rareB share common + rare, so the rare tag lifts the weight higher.
    let rareEdge = edge(edges, between: rareA.id, and: rareB.id)

    #expect(rareEdge != nil)
    #expect(rareEdge!.weight > (commonEdge?.weight ?? 0))
    #expect(rareEdge!.kinds.contains(.sharedTag))
}

@Test func semanticEdgeFires() {
    let a = Memory(content: "a")
    let b = Memory(content: "b")
    let neighbors: [UUID: [(id: UUID, distance: Double)]] = [
        a.id: [(id: b.id, distance: 0.1)]
    ]

    let edges = MemoryGraphBuilder.blend(memories: [a, b], neighbors: neighbors)

    let semantic = edge(edges, between: a.id, and: b.id)
    #expect(semantic != nil)
    #expect(semantic!.kinds.contains(.semantic))
}

private func makeTempStore() throws -> (MemoryStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-test-\(UUID().uuidString).sqlite")
    return (try MemoryStore(url: url), url)
}

@Test func graphBuildsFromStoreWithValidEdges() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let contents: [(content: String, tag: String)] = [
        ("Deploying services to the Kubernetes cluster via ArgoCD.", "infra"),
        ("The cluster autoscaler adds nodes under deployment load.", "infra"),
        ("Helm charts describe each Kubernetes deployment.", "infra"),
        ("My favourite pizza topping is mushrooms.", "food"),
        ("Fresh pasta needs only flour, eggs, and salt.", "food"),
        ("Slow-cooking the tomato sauce deepens the flavour.", "food"),
    ]
    for item in contents {
        try await store.store(content: item.content, tags: [item.tag])
    }

    let graph = try await store.graph()

    #expect(graph.nodes.count == contents.count)
    #expect(!graph.edges.isEmpty)

    let nodeIDs = Set(graph.nodes.map(\.id))
    #expect(graph.edges.allSatisfy { nodeIDs.contains($0.a) && nodeIDs.contains($0.b) })
}

@Test func pruningCapsDegree() {
    let config = GraphConfig(neighborsPerNode: 3)
    // A hub with many strong semantic neighbours — more candidates than k.
    let hub = Memory(content: "hub")
    let spokes = (0..<10).map { Memory(content: "s\($0)") }
    let memories = [hub] + spokes
    // Hub is a close neighbour of every spoke; spokes are also closely connected
    // to each other (closer than to the hub), so each spoke's own top-k is filled
    // by peers and rarely keeps the hub. The hub thus survives mainly via its own
    // top-k, capping its degree near k.
    var neighbors: [UUID: [(id: UUID, distance: Double)]] = [:]
    neighbors[hub.id] = spokes.map { (id: $0.id, distance: 0.4) }
    for (i, spoke) in spokes.enumerated() {
        var hits: [(id: UUID, distance: Double)] = spokes.enumerated()
            .filter { $0.offset != i }
            .map { (id: $0.element.id, distance: 0.1) }
        hits.append((id: hub.id, distance: 0.4))
        neighbors[spoke.id] = hits
    }

    let edges = MemoryGraphBuilder.blend(memories: memories, neighbors: neighbors, config: config)

    // Union rule bounds a node's degree at ~2k. The hub has far more candidate
    // edges than k, so pruning must cap (but not zero) its degree.
    let hubDegree = edges.filter { $0.a == hub.id || $0.b == hub.id }.count
    #expect(hubDegree <= 2 * config.neighborsPerNode)
    #expect(hubDegree >= config.neighborsPerNode)
}
