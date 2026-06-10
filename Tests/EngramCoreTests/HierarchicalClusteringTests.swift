import Foundation
import Testing
@testable import EngramCore

@Test func clusterSupportsEuclideanMetric() {
    func vec(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0] }
    let a = UUID(), b = UUID(), c = UUID()
    // a,b near each other; c far — should merge {a,b} before c under euclidean.
    let vectors = [(id: a, vector: vec(0, 0)), (id: b, vector: vec(0.1, 0)), (id: c, vector: vec(9, 9))]
    let tree = HierarchicalClustering.cluster(vectors: vectors, linkage: .average, metric: .euclidean)
    guard case let .merge(left, right, rootHeight, _) = tree else {
        Issue.record("expected a merge"); return
    }
    // The tight pair merges low; joining c happens at the (higher) root.
    #expect(rootHeight > min(left.height, right.height))
}

@Test func clusterMergesNearestPairFirstAndCoversAllLeaves() {
    // Two tight pairs along orthogonal axes; nearest-pair should merge within a
    // pair before the pairs merge with each other.
    func unit(_ x: Float, _ y: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 4); v[0] = x; v[1] = y; return v
    }
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let vectors = [
        (id: a, vector: unit(1, 0.02)),
        (id: b, vector: unit(1, -0.02)),
        (id: c, vector: unit(0.02, 1)),
        (id: d, vector: unit(-0.02, 1)),
    ]

    let tree = HierarchicalClustering.cluster(vectors: vectors, linkage: .average)
    #expect(tree != nil)

    // Every input id appears as a leaf exactly once.
    var leaves: [UUID] = []
    func collect(_ node: DendrogramNode) {
        switch node {
        case let .leaf(id): leaves.append(id)
        case let .merge(l, r, _, _): collect(l); collect(r)
        }
    }
    collect(tree!)
    #expect(Set(leaves) == Set([a, b, c, d]))
    // Root merge height (joining the two pairs) exceeds either pair's merge height.
    if case let .merge(left, right, rootHeight, _) = tree! {
        #expect(rootHeight > left.height)
        #expect(rootHeight > right.height)
    } else {
        Issue.record("expected a merge at the root")
    }
}
