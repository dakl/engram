import Foundation
import Testing

/// Returns the package root directory, derived from this source file's path.
private func packageRoot() -> URL {
    URL(fileURLWithPath: #file)
        .deletingLastPathComponent() // EngramCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // package root
}

/// Runs the engram CLI binary against a caller-supplied database URL.
/// Returns the combined stdout+stderr output and the exit code.
private func engram(_ args: [String], db: URL) throws -> (output: String, exitCode: Int32) {
    let root = packageRoot()
    // CI builds with `swift build --product engram` before running tests.
    // Locally: run `swift build --product engram` once to satisfy these tests.
    let debugBinary = root.appendingPathComponent(".build/debug/engram")
    let releaseBinary = root.appendingPathComponent(".build/release/engram")
    let binary: URL
    if FileManager.default.isExecutableFile(atPath: releaseBinary.path) {
        binary = releaseBinary
    } else if FileManager.default.isExecutableFile(atPath: debugBinary.path) {
        binary = debugBinary
    } else {
        return ("binary not found", -1)
    }

    let process = Process()
    process.executableURL = binary
    process.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["ENGRAM_DB"] = db.path
    process.environment = env

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (output, process.terminationStatus)
}

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-cli-smoke-\(UUID().uuidString).sqlite")
}

/// Basic store → fetch → stats round-trip. Verifies the CLI exits 0 and that
/// stored content is surfaced by a subsequent fetch.
@Test func cliStoreAndFetchRoundTrip() throws {
    let db = tempDB()
    defer { try? FileManager.default.removeItem(at: db) }

    let (_, storeExit) = try engram(["store", "the capital of France is Paris"], db: db)
    guard storeExit != -1 else { return } // binary not built — skip
    #expect(storeExit == 0, "engram store must exit 0")

    let (fetchOut, fetchExit) = try engram(["fetch", "What is the capital of France?", "--limit", "3"], db: db)
    #expect(fetchExit == 0, "engram fetch must exit 0")
    #expect(fetchOut.contains("Paris"), "fetch output must include the stored content")
}

/// The store argument forms the model actually reaches for must all succeed:
/// positional content, `--content`, and `--text`. Historically only positional
/// worked, so `engram store --content "…"` failed silently with "missing
/// content" — a real cause of un-saved memories (see the store-robustness work).
@Test func cliStoreAcceptsContentAndTextFlags() throws {
    for (label, args) in [
        ("positional", ["store", "alpha fact about Paris"]),
        ("--content", ["store", "--content", "beta fact about Paris"]),
        ("--text", ["store", "--text", "gamma fact about Paris"]),
    ] {
        let db = tempDB()
        defer { try? FileManager.default.removeItem(at: db) }

        let (out, exit) = try engram(args, db: db)
        guard exit != -1 else { return } // binary not built — skip
        #expect(exit == 0, "engram \(label) store must exit 0 (got: \(out))")
        #expect(out.hasPrefix("stored "), "\(label) store must report success")

        let (fetchOut, _) = try engram(["fetch", "Paris", "--limit", "3"], db: db)
        #expect(fetchOut.contains("Paris"), "\(label): stored content must be fetchable")
    }
}

/// A store with no content (any form) fails non-zero with an actionable message
/// that points at the correct invocation — not a bare "missing content".
@Test func cliStoreWithoutContentFailsWithHelpfulMessage() throws {
    let db = tempDB()
    defer { try? FileManager.default.removeItem(at: db) }

    let (out, exit) = try engram(["store"], db: db)
    guard exit != -1 else { return } // binary not built — skip
    #expect(exit != 0, "a content-less store must fail")
    #expect(out.contains("--content") && out.contains("engram store"),
            "the error must show the correct invocation forms (got: \(out))")
}

/// `engram stats` exits 0 and emits JSON with a numeric totalActive field.
@Test func cliStatsJSON() throws {
    let db = tempDB()
    defer { try? FileManager.default.removeItem(at: db) }

    _ = try engram(["store", "a memory for stats"], db: db)
    let (out, exit) = try engram(["stats", "--json"], db: db)
    guard exit != -1 else { return } // binary not built — skip
    #expect(exit == 0, "engram stats --json must exit 0")

    let data = Data(out.utf8)
    let json = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                            "stats --json must emit valid JSON")
    // CLI uses snake_case keys (see main.swift printJSON call for "stats").
    let total = json["total_active"] as? Int
    #expect(total == 1, "total_active should be 1 after one store")
}

/// `engram activity` exits 0 and lists the store event.
@Test func cliActivityAfterStore() throws {
    let db = tempDB()
    defer { try? FileManager.default.removeItem(at: db) }

    let (_, storeExit) = try engram(["store", "activity smoke test memory"], db: db)
    guard storeExit != -1 else { return } // binary not built — skip
    #expect(storeExit == 0)

    let (actOut, actExit) = try engram(["activity", "--since", "5m", "--json"], db: db)
    #expect(actExit == 0, "engram activity must exit 0")
    #expect(!actOut.isEmpty, "activity output must not be empty after a store")
}
