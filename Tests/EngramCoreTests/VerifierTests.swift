import Foundation
import Testing
@testable import EngramCore

private let fixedNow = Date(timeIntervalSince1970: 1_750_000_000) // 2025-06-15

/// `fileExists` that reports a fixed set of paths as present.
private func presentPaths(_ paths: Set<String>) -> (URL) -> Bool {
    { paths.contains($0.path) }
}

/// Default `branchExists` for tests that don't exercise branch anchors: fails
/// the test if consulted, so file-path/age tests prove branches aren't probed.
private func unusedBranchExists(_ name: String) -> Bool {
    Issue.record("branchExists should not be consulted for this anchor")
    return false
}

@Test func userConfirmOnlyIsInconclusive() {
    let memory = Memory(content: "Daniel likes mushrooms.", verifiability: .userConfirmOnly,
                        checkAnchor: "Sources/x.swift")
    let result = Verifier.verdict(for: memory, repoRoot: URL(fileURLWithPath: "/repo"),
                                  fileExists: { _ in true }, branchExists: { _ in false }, now: fixedNow)
    #expect(result.verdict == .inconclusive)
}

@Test func timelessIsInconclusive() {
    let memory = Memory(content: "Pi is roughly 3.14.", verifiability: .timeless)
    let result = Verifier.verdict(for: memory, repoRoot: nil, fileExists: { _ in false },
                                  branchExists: { _ in false }, now: fixedNow)
    #expect(result.verdict == .inconclusive)
}

@Test func existingAnchorFileIsConfirmed() {
    let repoRoot = URL(fileURLWithPath: "/repo")
    let memory = Memory(content: "Auth lives in Auth.swift.", verifiability: .codeGrounded,
                        checkAnchor: "Sources/Auth.swift")
    let exists = presentPaths(["/repo", "/repo/Sources/Auth.swift"])
    let result = Verifier.verdict(for: memory, repoRoot: repoRoot, fileExists: exists,
                                  branchExists: unusedBranchExists, now: fixedNow)
    #expect(result.verdict == .confirmed)
}

@Test func missingAnchorFileIsContradicted() {
    let repoRoot = URL(fileURLWithPath: "/repo")
    let memory = Memory(content: "Auth lives in Auth.swift.", verifiability: .codeGrounded,
                        checkAnchor: "x.swift")
    let result = Verifier.verdict(for: memory, repoRoot: repoRoot,
                                  fileExists: presentPaths(["/repo"]),
                                  branchExists: unusedBranchExists, now: fixedNow)
    #expect(result.verdict == .contradicted)
}

@Test func anchorWithMissingRepoRootIsInconclusive() {
    let memory = Memory(content: "Auth lives in Auth.swift.", verifiability: .codeGrounded,
                        checkAnchor: "x.swift")
    // Repo root nil.
    #expect(Verifier.verdict(for: memory, repoRoot: nil, fileExists: { _ in true },
                             branchExists: { _ in false }, now: fixedNow).verdict == .inconclusive)
    // Repo root set but its directory doesn't exist.
    let result = Verifier.verdict(for: memory, repoRoot: URL(fileURLWithPath: "/nope"),
                                  fileExists: { _ in false }, branchExists: { _ in false }, now: fixedNow)
    #expect(result.verdict == .inconclusive)
}

@Test func nonPathAnchorIsNotTreatedAsFile() {
    // Anchor with a space is not a file path → falls through to age/default.
    let memory = Memory(content: "Some note.", verifiability: .codeGrounded,
                        checkAnchor: "grep for FooBar in handlers")
    let result = Verifier.verdict(for: memory, repoRoot: URL(fileURLWithPath: "/repo"),
                                  fileExists: { _ in true }, branchExists: { _ in false }, now: fixedNow)
    #expect(result.verdict == .inconclusive)
}

@Test func oldAsOfDateIsStale() {
    let memory = Memory(content: "The cluster runs v1.2 as of 2020-01-01.", verifiability: .configInfra)
    let result = Verifier.verdict(for: memory, repoRoot: nil, fileExists: { _ in false },
                                  branchExists: { _ in false }, now: fixedNow)
    #expect(result.verdict == .stale)
}

@Test func recentAsOfDateIsInconclusive() {
    let memory = Memory(content: "The cluster runs v1.2 as of 2025-06-01.", verifiability: .configInfra)
    let result = Verifier.verdict(for: memory, repoRoot: nil, fileExists: { _ in false },
                                  branchExists: { _ in false }, now: fixedNow)
    #expect(result.verdict == .inconclusive)
}

@Test func noSignalsIsInconclusive() {
    let memory = Memory(content: "A plain decision note.", verifiability: .decision)
    let result = Verifier.verdict(for: memory, repoRoot: nil, fileExists: { _ in false },
                                  branchExists: { _ in false }, now: fixedNow)
    #expect(result.verdict == .inconclusive)
}

@Test func presentBranchAnchorIsConfirmed() {
    let memory = Memory(content: "Streaming parser lives on its branch.", verifiability: .projectState,
                        checkAnchor: "branch:SAAG-82-streaming-parser")
    let result = Verifier.verdict(
        for: memory, repoRoot: URL(fileURLWithPath: "/repo"),
        // fileExists must not decide a branch anchor.
        fileExists: { _ in Issue.record("fileExists should not be consulted for a branch anchor"); return false },
        branchExists: { $0 == "SAAG-82-streaming-parser" }, now: fixedNow
    )
    #expect(result.verdict == .confirmed)
}

@Test func goneBranchAnchorIsStale() {
    let memory = Memory(content: "Streaming parser lives on its branch.", verifiability: .projectState,
                        checkAnchor: "branch:SAAG-82-streaming-parser")
    let result = Verifier.verdict(
        for: memory, repoRoot: URL(fileURLWithPath: "/repo"),
        fileExists: { _ in true }, branchExists: { _ in false }, now: fixedNow
    )
    #expect(result.verdict == .stale)
}
