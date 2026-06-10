import Foundation
import Testing
@testable import EngramCore

private let fixedNow = Date(timeIntervalSince1970: 1_750_000_000) // 2025-06-15
private let oneYearAgo = fixedNow.addingTimeInterval(-365 * 86_400)
private let yesterday = fixedNow.addingTimeInterval(-86_400)

@Test func oldCodeGroundedOutranksFresh() {
    let old = Memory(content: "old", createdAt: oneYearAgo, verifiability: .codeGrounded)
    let fresh = Memory(content: "fresh", createdAt: yesterday, verifiability: .codeGrounded)
    #expect(Ranking.rotRisk(for: old, now: fixedNow) > Ranking.rotRisk(for: fresh, now: fixedNow))
}

@Test func excludedClassesScoreZero() {
    let userConfirm = Memory(content: "a", createdAt: oneYearAgo, accessCount: 99,
                             verifiability: .userConfirmOnly)
    let timeless = Memory(content: "b", createdAt: oneYearAgo, accessCount: 99,
                          verifiability: .timeless)
    #expect(Ranking.rotRisk(for: userConfirm, now: fixedNow) == 0)
    #expect(Ranking.rotRisk(for: timeless, now: fixedNow) == 0)
}

@Test func higherAccessCountRaisesRisk() {
    let unused = Memory(content: "a", createdAt: oneYearAgo, accessCount: 0,
                        verifiability: .codeGrounded)
    let popular = Memory(content: "b", createdAt: oneYearAgo, accessCount: 50,
                         verifiability: .codeGrounded)
    #expect(Ranking.rotRisk(for: popular, now: fixedNow) > Ranking.rotRisk(for: unused, now: fixedNow))
}

@Test func verifiedAtTakesPrecedenceOverCreatedAt() {
    // Created long ago but verified yesterday → low risk despite old createdAt.
    let recentlyVerified = Memory(content: "a", createdAt: oneYearAgo,
                                  verifiability: .codeGrounded, verifiedAt: yesterday)
    let neverVerified = Memory(content: "b", createdAt: oneYearAgo, verifiability: .codeGrounded)
    #expect(Ranking.rotRisk(for: recentlyVerified, now: fixedNow)
        < Ranking.rotRisk(for: neverVerified, now: fixedNow))
}

@Test func descendingRiskOrdering() {
    // projectState is the most volatile; an excluded class lands last.
    let memories = [
        Memory(content: "stale-project", createdAt: oneYearAgo, accessCount: 10, verifiability: .projectState),
        Memory(content: "stale-code", createdAt: oneYearAgo, accessCount: 10, verifiability: .codeGrounded),
        Memory(content: "stale-decision", createdAt: oneYearAgo, accessCount: 10, verifiability: .decision),
        Memory(content: "user-confirm", createdAt: oneYearAgo, accessCount: 10, verifiability: .userConfirmOnly),
    ]
    let ordered = memories.sorted {
        Ranking.rotRisk(for: $0, now: fixedNow) > Ranking.rotRisk(for: $1, now: fixedNow)
    }
    #expect(ordered.map(\.content) == ["stale-project", "stale-code", "stale-decision", "user-confirm"])
}
