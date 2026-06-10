import Foundation

/// A named set of memories used by a graph lens to colour, cluster, and label
/// nodes (ADR 0011). Communities (Louvain) are one grouping; `LensGrouping`
/// derives the others (by source now, more later) as pure functions.
public struct MemoryGroup: Sendable, Identifiable {
    public let id: Int
    public let label: String
    public let memberIDs: [UUID]

    public init(id: Int, label: String, memberIDs: [UUID]) {
        self.id = id
        self.label = label
        self.memberIDs = memberIDs
    }
}

/// Pure groupings of memories for the graph lenses.
public enum LensGrouping {
    /// Placeholder label for memories that carry no `source`.
    public static let noSourceLabel = "no source"
    /// Placeholder label for memories that carry no tags.
    public static let untaggedLabel = "untagged"

    /// Groups memories by their most *distinctive* tag — the one shared by the
    /// fewest other memories (idf-style), ties broken alphabetically — so each
    /// group is a specific topic rather than a catch-all. Untagged memories form
    /// one bucket placed last. Same deterministic size-then-label ordering as
    /// `bySource`, with the untagged bucket last.
    public static func byTag(_ memories: [Memory]) -> [MemoryGroup] {
        var frequency: [String: Int] = [:]
        for memory in memories {
            for tag in Set(memory.tags) { frequency[tag, default: 0] += 1 }
        }

        var idsByTag: [String: [UUID]] = [:]
        for memory in memories {
            let tags = Set(memory.tags)
            if tags.isEmpty {
                idsByTag[untaggedLabel, default: []].append(memory.id)
                continue
            }
            // Rarest tag wins (lowest frequency), ties broken alphabetically.
            let chosen = tags.min { lhs, rhs in
                let lf = frequency[lhs, default: 0], rf = frequency[rhs, default: 0]
                return lf != rf ? lf < rf : lhs < rhs
            }!
            idsByTag[chosen, default: []].append(memory.id)
        }

        return order(idsByLabel: idsByTag, lastLabel: untaggedLabel)
    }

    /// Groups memories by `source`. Ordering is deterministic — larger groups
    /// first, ties broken by label — with the "no source" bucket always last so
    /// its colour stays stable as the store grows.
    public static func bySource(_ memories: [Memory]) -> [MemoryGroup] {
        var idsByLabel: [String: [UUID]] = [:]
        for memory in memories {
            let label = memory.source.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let key = label.isEmpty ? noSourceLabel : label
            idsByLabel[key, default: []].append(memory.id)
        }
        return order(idsByLabel: idsByLabel, lastLabel: noSourceLabel)
    }

    /// Shared deterministic ordering: larger groups first, ties by label, with
    /// `lastLabel` (the catch-all bucket) always last so its colour stays stable.
    private static func order(idsByLabel: [String: [UUID]], lastLabel: String) -> [MemoryGroup] {
        let sortedLabels = idsByLabel.keys.sorted { left, right in
            if left == lastLabel { return false }
            if right == lastLabel { return true }
            let leftCount = idsByLabel[left]!.count
            let rightCount = idsByLabel[right]!.count
            if leftCount != rightCount { return leftCount > rightCount }
            return left < right
        }
        return sortedLabels.enumerated().map { index, label in
            MemoryGroup(id: index, label: label, memberIDs: idsByLabel[label]!)
        }
    }
}
