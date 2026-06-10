import Foundation
import Testing
@testable import EngramCore

@Test func treeOutlineSeparatesLeavesAndClusters() {
    let a = UUID(), b = UUID()
    let memories: [UUID: Memory] = [
        a: Memory(id: a, content: "alpha"),
        b: Memory(id: b, content: "beta"),
    ]
    let root = DendrogramNode.merge(left: .leaf(a), right: .leaf(b), height: 0.5, size: 2)

    // colorCount 1 ⇒ no cut, so the root cluster is the single top-level node.
    let roots = TreeOutline.build(root: root, memories: memories, colorCount: 1)
    #expect(roots.count == 1)

    let cluster = roots[0]
    guard case let .cluster(memberCount, height, _) = cluster.kind else {
        Issue.record("expected a cluster at the root"); return
    }
    #expect(memberCount == 2)
    #expect(height == 0.5)
    #expect(cluster.children?.count == 2)

    let leafIDs = Set(cluster.children?.compactMap { $0.memory?.id } ?? [])
    #expect(leafIDs == Set([a, b]))
    #expect(cluster.children?.allSatisfy { $0.children == nil } == true)
}

@Test func treeOutlineCutsIntoTwoColoredSubtrees() {
    let ids = (0..<4).map { _ in UUID() }
    let memories = Dictionary(uniqueKeysWithValues: ids.map { ($0, Memory(id: $0, content: "m")) })
    // ((a,b) low) and ((c,d) low) join at a much higher root.
    let left = DendrogramNode.merge(left: .leaf(ids[0]), right: .leaf(ids[1]), height: 0.2, size: 2)
    let right = DendrogramNode.merge(left: .leaf(ids[2]), right: .leaf(ids[3]), height: 0.3, size: 2)
    let root = DendrogramNode.merge(left: left, right: right, height: 0.9, size: 4)

    // Two clear clusters ⇒ two colored cut subtrees at the top level.
    let roots = TreeOutline.build(root: root, memories: memories, colorCount: 2)
    #expect(roots.count == 2)

    let colors = roots.compactMap(\.colorIndex)
    #expect(colors.count == 2)
    #expect(Set(colors).count == 2)

    // Every returned root is a 2-member cluster; all four leaves are covered.
    var leaves: [UUID] = []
    func collect(_ node: TreeOutline.TreeNode) {
        if let memory = node.memory { leaves.append(memory.id) }
        node.children?.forEach(collect)
    }
    roots.forEach(collect)
    #expect(Set(leaves) == Set(ids))

    // A leaf inherits its cut cluster's color.
    for cutCluster in roots {
        let leafColors = cutCluster.children?.compactMap(\.colorIndex) ?? []
        #expect(leafColors.allSatisfy { $0 == cutCluster.colorIndex })
    }
}

@Test func treeOutlineLabelsClusterByDominantTag() {
    let a = UUID(), b = UUID()
    let memories: [UUID: Memory] = [
        a: Memory(id: a, content: "alpha", tags: ["infra", "gcp"]),
        b: Memory(id: b, content: "beta", tags: ["infra"]),
    ]
    let root = DendrogramNode.merge(left: .leaf(a), right: .leaf(b), height: 0.5, size: 2)
    let roots = TreeOutline.build(root: root, memories: memories, colorCount: 1)
    #expect(roots.first?.label == "infra")
}
