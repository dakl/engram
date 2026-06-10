import Foundation

/// Builds a native-outline node model from a hierarchical-clustering result
/// (ADR 0017): the same cut-coloring the old vertical dendrogram used, but shaped
/// as a tree of `TreeNode`s that a SwiftUI `OutlineGroup` can render directly.
/// Pure and deterministic; the view just walks the result.
public enum TreeOutline {
    /// One node in the outline. A cluster node has `children`; a leaf node carries
    /// its `Memory` and has `children == nil`.
    public struct TreeNode: Identifiable, Sendable {
        public enum Kind: Sendable {
            /// An internal merge: how many leaves it spans, the merge height it
            /// joined at, and the cut-cluster color (`nil` ⇒ neutral, above the cut).
            case cluster(memberCount: Int, height: Double, colorIndex: Int?)
            /// A leaf memory, colored by the cut-cluster it belongs to (`nil` ⇒ its
            /// own subtree never dropped below the cut).
            case leaf(Memory, colorIndex: Int?)
        }

        public let id: UUID
        public let kind: Kind
        /// `nil` for a leaf; a (possibly empty) array for a cluster.
        public let children: [TreeNode]?
        /// A short label for cluster rows: the members' most common tag if there
        /// is a clear one, otherwise empty (the view falls back to "N memories").
        public let label: String

        public init(id: UUID, kind: Kind, children: [TreeNode]?, label: String) {
            self.id = id
            self.kind = kind
            self.children = children
            self.label = label
        }

        /// Convenience for the view: the leaf's memory, or nil for a cluster.
        public var memory: Memory? {
            if case let .leaf(memory, _) = kind { return memory }
            return nil
        }

        /// Convenience for the view: this node's cut-cluster color index.
        public var colorIndex: Int? {
            switch kind {
            case let .cluster(_, _, colorIndex): return colorIndex
            case let .leaf(_, colorIndex): return colorIndex
            }
        }
    }

    /// Builds the outline. The returned array is the set of **cut clusters** — the
    /// subtrees the dendrogram splits into for `colorCount` colors — each a colored
    /// subtree; clusters at/above the cut are returned as their own (neutral) roots
    /// only when the root itself sits above the cut. Reuses the cut-coloring logic
    /// from the old vertical layout: a subtree claims a color index once it drops
    /// below the cut threshold; everything above stays neutral (`colorIndex == nil`).
    public static func build(
        root: DendrogramNode,
        memories: [UUID: Memory],
        colorCount: Int = 8
    ) -> [TreeNode] {
        let threshold = cutThreshold(root, colorCount: colorCount)
        var nextColor = 0
        func newColor() -> Int { defer { nextColor += 1 }; return nextColor }

        // Builds a node and its subtree, carrying down the claimed color (nil while
        // still above the cut). Returns the built node plus the multiset of member
        // tags, so a cluster can label itself by its members' most common tag.
        func place(_ node: DendrogramNode, color: Int?) -> (node: TreeNode, tagCounts: [String: Int]) {
            switch node {
            case let .leaf(id):
                let memory = memories[id]
                let leafColor = color
                var tags: [String: Int] = [:]
                if let memory {
                    for tag in memory.tags { tags[tag, default: 0] += 1 }
                }
                let kind: TreeNode.Kind = .leaf(memory ?? Memory(content: "(missing memory)"),
                                                colorIndex: leafColor)
                // Use the memory id when present so selection round-trips; a missing
                // memory still needs a stable id, so fall back to the leaf id.
                let nodeID = memory?.id ?? id
                return (TreeNode(id: nodeID, kind: kind, children: nil, label: ""), tags)

            case let .merge(left, right, height, size):
                let childColor: Int?
                let clusterColor: Int?
                if let color {
                    childColor = color
                    clusterColor = color
                } else if height < threshold {
                    let claimed = newColor()
                    childColor = claimed
                    clusterColor = claimed
                } else {
                    childColor = nil
                    clusterColor = nil
                }
                let leftBuilt = place(left, color: childColor)
                let rightBuilt = place(right, color: childColor)
                var tags = leftBuilt.tagCounts
                for (tag, count) in rightBuilt.tagCounts { tags[tag, default: 0] += count }
                let kind: TreeNode.Kind = .cluster(memberCount: size, height: height,
                                                   colorIndex: clusterColor)
                let node = TreeNode(id: UUID(), kind: kind,
                                    children: [leftBuilt.node, rightBuilt.node],
                                    label: dominantTag(tags))
                return (node, tags)
            }
        }

        let built = place(root, color: nil).node
        // Top-level returned nodes are the cut clusters: if the root is itself a
        // colored cut cluster (small store, root below threshold), return it; else
        // peel the neutral spine away and surface the colored cut clusters.
        return cutClusters(built)
    }

    /// Walks down from a (possibly neutral) root, returning the highest nodes that
    /// carry a color — the cut clusters. A leaf with no color is its own cluster.
    private static func cutClusters(_ node: TreeNode) -> [TreeNode] {
        if node.colorIndex != nil { return [node] }
        guard let children = node.children, !children.isEmpty else { return [node] }
        return children.flatMap(cutClusters)
    }

    /// The members' most common tag, but only if it clearly dominates (appears in a
    /// majority and is unique at the top). Otherwise empty.
    private static func dominantTag(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "" }
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let top = sorted.first else { return "" }
        let total = counts.values.reduce(0, +)
        let isMajority = top.value * 2 >= total
        let isUnique = sorted.count == 1 || sorted[1].value < top.value
        return (isMajority && isUnique) ? top.key : ""
    }

    /// The merge height above which the tree is "cut" into `colorCount` clusters;
    /// `+∞` when there aren't enough merges to split (so nothing gets a color).
    private static func cutThreshold(_ root: DendrogramNode, colorCount: Int) -> Double {
        guard colorCount > 1 else { return .infinity }
        var heights: [Double] = []
        func collect(_ node: DendrogramNode) {
            if case let .merge(left, right, height, _) = node {
                heights.append(height)
                collect(left)
                collect(right)
            }
        }
        collect(root)
        guard heights.count >= colorCount - 1 else { return .infinity }
        return heights.sorted(by: >)[colorCount - 2]
    }
}
