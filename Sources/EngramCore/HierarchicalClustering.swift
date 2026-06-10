import Foundation

/// A node in a hierarchical-agglomerative-clustering result (ADR 0011). Leaves
/// are memories; a merge records the distance (`height`) at which its two
/// children joined, which is what makes a dendrogram informative.
public indirect enum DendrogramNode: Sendable {
    case leaf(UUID)
    case merge(left: DendrogramNode, right: DendrogramNode, height: Double, size: Int)

    /// Merge height (0 for a leaf).
    public var height: Double {
        switch self {
        case .leaf: 0
        case let .merge(_, _, height, _): height
        }
    }
}

/// Cluster-distance definitions for agglomerative clustering, all expressed
/// through the Lance-Williams update so one engine serves every method.
public enum Linkage: String, Sendable, CaseIterable {
    case average  // UPGMA — mean pairwise distance
    case ward     // minimum within-cluster variance increase
    case complete // farthest pair
    case single   // nearest pair
}

/// Point-to-point distance between memory embedding vectors.
public enum DistanceMetric: String, Sendable, CaseIterable {
    case cosine    // 1 − cosine similarity (direction); ignores magnitude
    case euclidean // straight-line distance; the principled pair for Ward
}

/// Hierarchical agglomerative clustering over memory embedding vectors.
public enum HierarchicalClustering {
    /// Clusters memories bottom-up by the chosen `metric`, merging the closest
    /// pair each step (Lance-Williams update for the chosen `linkage`).
    /// Deterministic: inputs are sorted by id and ties broken by index. Returns
    /// `nil` for empty input. O(n²) memory, O(n³) time — fine for the hundreds of
    /// active memories.
    public static func cluster(
        vectors: [(id: UUID, vector: [Float])],
        linkage: Linkage,
        metric: DistanceMetric = .cosine
    ) -> DendrogramNode? {
        let items = vectors.sorted { $0.id.uuidString < $1.id.uuidString }
        let n = items.count
        guard n > 0 else { return nil }
        guard n > 1 else { return .leaf(items[0].id) }

        let prepared: [[Double]] = metric == .cosine
            ? items.map { normalize($0.vector) }
            : items.map { $0.vector.map(Double.init) }
        var distance = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = metric == .cosine
                    ? 1.0 - dot(prepared[i], prepared[j])
                    : euclidean(prepared[i], prepared[j])
                distance[i][j] = d
                distance[j][i] = d
            }
        }

        var node: [DendrogramNode] = items.map { .leaf($0.id) }
        var size = [Int](repeating: 1, count: n)
        var alive = Array(0..<n)

        while alive.count > 1 {
            // Closest active pair (sorted indices ⇒ deterministic tie-breaking).
            var best = (distance: Double.greatestFiniteMagnitude, a: -1, b: -1)
            for a in 0..<(alive.count - 1) {
                for b in (a + 1)..<alive.count {
                    let i = alive[a], j = alive[b]
                    if distance[i][j] < best.distance { best = (distance[i][j], i, j) }
                }
            }
            let (height, i, j) = best
            let ni = Double(size[i]), nj = Double(size[j])

            for k in alive where k != i && k != j {
                let dik = distance[i][k], djk = distance[j][k]
                let nk = Double(size[k])
                let updated: Double
                switch linkage {
                case .single: updated = min(dik, djk)
                case .complete: updated = max(dik, djk)
                case .average: updated = (ni * dik + nj * djk) / (ni + nj)
                case .ward: updated = ((ni + nk) * dik + (nj + nk) * djk - nk * height) / (ni + nj + nk)
                }
                distance[i][k] = updated
                distance[k][i] = updated
            }

            node[i] = .merge(left: node[i], right: node[j], height: height, size: size[i] + size[j])
            size[i] += size[j]
            alive.removeAll { $0 == j }
        }
        return node[alive[0]]
    }

    private static func normalize(_ vector: [Float]) -> [Double] {
        let doubles = vector.map(Double.init)
        let norm = doubles.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return doubles }
        return doubles.map { $0 / norm }
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }

    private static func euclidean(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for index in 0..<min(a.count, b.count) {
            let delta = a[index] - b[index]
            sum += delta * delta
        }
        return sum.squareRoot()
    }
}
