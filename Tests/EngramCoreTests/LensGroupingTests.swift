import Foundation
import Testing
@testable import EngramCore

@Test func bySourceGroupsAndOrdersBySizeWithNoSourceLast() {
    let memories = [
        Memory(content: "a", source: "gitops"),
        Memory(content: "b", source: "gitops"),
        Memory(content: "c", source: "engram"),
        Memory(content: "d", source: nil),
        Memory(content: "e", source: "  "),
    ]

    let groups = LensGrouping.bySource(memories)

    #expect(groups.count == 3)
    // Largest group (gitops, 2) first; engram (1) next; no-source bucket last.
    #expect(groups[0].label == "gitops")
    #expect(groups[0].memberIDs.count == 2)
    #expect(groups[1].label == "engram")
    #expect(groups.last?.label == LensGrouping.noSourceLabel)
    // Blank and nil sources both land in the no-source bucket.
    #expect(groups.last?.memberIDs.count == 2)
}

@Test func byTagChoosesTheRarestTagAndBucketsUntagged() {
    // "common" appears on all three; "rare-x" on one each. Each memory should be
    // grouped under its rare tag, not the shared common one.
    let m1 = Memory(content: "1", tags: ["common", "rare-a"])
    let m2 = Memory(content: "2", tags: ["common", "rare-b"])
    let m3 = Memory(content: "3", tags: ["common", "rare-c"])
    let m4 = Memory(content: "4", tags: [])

    let groups = LensGrouping.byTag([m1, m2, m3, m4])
    let labels = Set(groups.map(\.label))

    #expect(labels == ["rare-a", "rare-b", "rare-c", LensGrouping.untaggedLabel])
    #expect(!labels.contains("common"))
    #expect(groups.last?.label == LensGrouping.untaggedLabel)
}

@Test func bySourceCoversEveryMemoryExactlyOnce() {
    let memories = (0..<10).map { Memory(content: "m\($0)", source: $0.isMultiple(of: 2) ? "repo" : nil) }
    let groups = LensGrouping.bySource(memories)
    let grouped = groups.flatMap(\.memberIDs)
    #expect(Set(grouped) == Set(memories.map(\.id)))
    #expect(grouped.count == memories.count)
}
