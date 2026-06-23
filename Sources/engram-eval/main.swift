import EngramCore
import Foundation

// Offline retrieval eval. Seeds a throwaway store from a labeled corpus, runs
// each prompt through `MemoryStore.fetch`, applies several `RecallGate` configs,
// and prints how each does on recall vs. false-positive injection.
//
// Numbers are machine-dependent (the embedder backend differs by what's
// downloaded), so treat this as a *relative* A/B of gate configs on one machine,
// not an absolute benchmark. Run: `swift run engram-eval`.

struct CorpusMemory: Decodable {
    let slug: String
    let content: String
    let tags: [String]?
}

struct EvalQuery: Decodable {
    let prompt: String
    let relevant: [String]
    let kind: String  // "targeted" | "multi" | "negative"
}

struct EvalSession: Decodable {
    let name: String
    let prompts: [String]
}

struct Corpus: Decodable { let memories: [CorpusMemory] }
struct QuerySet: Decodable { let queries: [EvalQuery] }
struct SessionSet: Decodable { let sessions: [EvalSession] }

func loadResource<T: Decodable>(_ name: String, as type: T.Type) -> T {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        fatalError("missing resource \(name).json")
    }
    do {
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    } catch {
        fatalError("failed to decode \(name).json: \(error)")
    }
}

let configs: [(name: String, config: RecallGateConfig)] = [
    ("current", .current),
    // Sweep the absolute distance ceiling at this embedder's real scale (~0.1),
    // with a lexical leg that demands ≥2 shared tokens (no single-keyword leak).
    ("calib-0.13", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.13, minLexicalTokenHits: 2)),
    ("calib-0.12", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.12, minLexicalTokenHits: 2)),
    ("calib-0.11", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.11, minLexicalTokenHits: 2)),
    ("calib-0.10", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.10, minLexicalTokenHits: 2)),
    ("calib-0.09", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.09, minLexicalTokenHits: 2)),
    ("calib-0.08", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.08, minLexicalTokenHits: 2)),
    // Tight distance, NO lexical leg: shows how far recall falls back on the
    // lexical floor when the semantic gate is nearly closed.
    ("calib-0.08-lex0", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.08, minLexicalTokenHits: 0)),
    ("calib-0.11-lex0", RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.11, minLexicalTokenHits: 0)),
]

func run() async throws {
    let corpus = loadResource("corpus", as: Corpus.self)
    let querySet = loadResource("queries", as: QuerySet.self)

    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-eval-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    let store = try MemoryStore(url: dbURL)

    // Seed; remember each memory's real id by slug.
    var idForSlug: [String: UUID] = [:]
    for memory in corpus.memories {
        let stored = try await store.store(content: memory.content, tags: memory.tags ?? [])
        idForSlug[memory.slug] = stored.id
    }

    print("embedder: \(await store.isUsingFallbackEmbedder ? "FALLBACK (word-512, degraded)" : "contextual")")
    print("corpus: \(corpus.memories.count) memories  ·  queries: \(querySet.queries.count)\n")

    // For each gate config, collect a per-query outcome.
    var outcomesByConfig: [String: [QueryOutcome]] = [:]
    var unresolved: Set<String> = []

    for query in querySet.queries {
        let results = (try? await store.fetch(query: query.prompt, limit: 8, recordAccess: false)) ?? []
        let ranked = results.map(\.memory.id)
        let relevant = Set(query.relevant.compactMap { slug -> UUID? in
            if let id = idForSlug[slug] { return id }
            unresolved.insert(slug)
            return nil
        })

        for (name, config) in configs {
            let injected = RecallGate.select(results, query: query.prompt, config: config).map(\.memory.id)
            outcomesByConfig[name, default: []].append(
                QueryOutcome(relevant: relevant, ranked: ranked, injected: injected)
            )
        }
    }

    if !unresolved.isEmpty {
        print("⚠️  query labels reference unknown slugs: \(unresolved.sorted().joined(separator: ", "))\n")
    }

    printTable(outcomesByConfig)

    // Session-aware injection (ADR 0023): replay ordered, on-topic prompt
    // sequences and measure how often the *same* memory is re-injected within a
    // session — with vs without the session cooldown the recall hook applies.
    let sessionSet = loadResource("sessions", as: SessionSet.self)
    let (noCooldown, withCooldown) = try await simulateSessions(store: store, sessions: sessionSet.sessions)
    let sessionRecord = SessionRunRecord(
        withoutCooldown: RetrievalMetrics.evaluateSessions(noCooldown),
        withCooldown: RetrievalMetrics.evaluateSessions(withCooldown),
        firstTouchCoverage: RetrievalMetrics.firstTouchCoverage(withoutCooldown: noCooldown, withCooldown: withCooldown)
    )
    printSessionTable(sessionRecord)

    if CommandLine.arguments.contains("--distances") {
        try await dumpDistances(store: store, querySet: querySet)
    }

    if CommandLine.arguments.contains("--dump-scores") {
        try await dumpScores(
            store: store, querySet: querySet, idForSlug: idForSlug,
            embedderSignature: await store.embedderSignature
        )
    }

    if CommandLine.arguments.contains("--record") {
        try recordRun(
            outcomesByConfig: outcomesByConfig,
            sessions: sessionRecord,
            embedderSignature: await store.embedderSignature,
            corpusSize: corpus.memories.count,
            queryCount: querySet.queries.count
        )
    }
}

/// Replays each session's prompts in order through `fetch` + the shipped gate
/// (`.current`), producing the per-prompt injected-id lists twice: once stateless
/// ("without cooldown" — the old behavior) and once applying the real
/// session-scoped cooldown (`recentlyInjectedInSession` + `recordRetrieval`,
/// ADR 0023) against a unique session id, exactly as the recall hook does.
func simulateSessions(store: MemoryStore, sessions: [EvalSession]) async throws
    -> (withoutCooldown: [[[UUID]]], withCooldown: [[[UUID]]]) {
    var without: [[[UUID]]] = []
    var withCd: [[[UUID]]] = []
    for session in sessions {
        var statelessLists: [[UUID]] = []
        var cooldownLists: [[UUID]] = []
        let sessionID = "eval-\(session.name)"
        for prompt in session.prompts {
            let results = (try? await store.fetch(query: prompt, limit: 8, recordAccess: false)) ?? []
            let confident = RecallGate.select(results, query: prompt, config: .current).map(\.memory.id)
            statelessLists.append(confident)

            let suppressed = (try? await store.recentlyInjectedInSession(
                confident, sessionID: sessionID, within: MemoryStore.recallReinjectionCooldown)) ?? []
            let fresh = confident.filter { !suppressed.contains($0) }
            if !fresh.isEmpty {
                try? await store.recordRetrieval(memoryIDs: fresh, source: .recall, query: prompt, sessionID: sessionID)
            }
            cooldownLists.append(fresh)
        }
        without.append(statelessLists)
        withCd.append(cooldownLists)
    }
    return (without, withCd)
}

// MARK: - Per-run recording (eval/runs/<timestamp>.json)

struct VariantResult: Encodable {
    let variant: String
    let report: RetrievalReport
}

struct SessionRunRecord: Encodable {
    let withoutCooldown: SessionInjectionReport
    let withCooldown: SessionInjectionReport
    let firstTouchCoverage: Double
}

struct RunRecord: Encodable {
    let timestamp: String
    let gitSha: String
    let host: String
    let embedderSignature: String
    let corpusSize: Int
    let queryCount: Int
    let k: Int
    let results: [VariantResult]
    let sessions: SessionRunRecord
}

/// Writes one JSON file per run under eval/runs/. The metadata (git sha, embedder
/// signature, host) is what makes a committed history comparable — the metrics
/// alone are meaningless without the embedder/scale they were measured on.
func recordRun(
    outcomesByConfig: [String: [QueryOutcome]],
    sessions: SessionRunRecord,
    embedderSignature: String,
    corpusSize: Int,
    queryCount: Int
) throws {
    let results = configs.compactMap { name, _ -> VariantResult? in
        guard let outcomes = outcomesByConfig[name] else { return nil }
        return VariantResult(variant: name, report: RetrievalMetrics.evaluate(outcomes, k: 3))
    }

    let iso = ISO8601DateFormatter()
    let timestamp = iso.string(from: Date())
    let record = RunRecord(
        timestamp: timestamp,
        gitSha: gitSha(),
        host: ProcessInfo.processInfo.hostName,
        embedderSignature: embedderSignature,
        corpusSize: corpusSize,
        queryCount: queryCount,
        k: 3,
        results: results,
        sessions: sessions
    )

    let runsDir = URL(fileURLWithPath: "eval/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
    let safeStamp = timestamp.replacingOccurrences(of: ":", with: "-")
    let fileURL = runsDir.appendingPathComponent("\(safeStamp)-\(embedderSignature).json")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: fileURL)
    print("\nrecorded → \(fileURL.path)")
}

func gitSha() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    } catch {
        return "unknown"
    }
}

/// Dumps every fetched candidate's semantic distance + whether it's relevant to
/// the query, so an external tool can plot ROC/PR curves over the distance
/// threshold and mark the shipped gate's ceiling. One row per (query, candidate)
/// with a finite distance (lexical-only candidates carry no distance). Writes
/// `eval/scores-<embedder>.json`.
func dumpScores(store: MemoryStore, querySet: QuerySet, idForSlug: [String: UUID], embedderSignature: String) async throws {
    struct ScoreRow: Encodable { let distance: Double; let relevant: Bool; let kind: String }
    var rows: [ScoreRow] = []
    for query in querySet.queries {
        let relevant = Set(query.relevant.compactMap { idForSlug[$0] })
        let results = (try? await store.fetch(query: query.prompt, limit: 8, recordAccess: false)) ?? []
        for result in results where result.distance.isFinite && result.distance < .greatestFiniteMagnitude {
            rows.append(ScoreRow(distance: result.distance, relevant: relevant.contains(result.memory.id), kind: query.kind))
        }
    }
    let dir = URL(fileURLWithPath: "eval", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("scores-\(embedderSignature).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode([
        "currentMaxDistance": RecallGateConfig.current.maxDistance,
        "proposedMaxDistance": RecallGateConfig.proposed.maxDistance,
    ]).write(to: dir.appendingPathComponent("thresholds-\(embedderSignature).json"))
    try encoder.encode(rows).write(to: fileURL)
    let pos = rows.filter(\.relevant).count
    print("\ndumped \(rows.count) candidate scores (\(pos) relevant) → \(fileURL.path)")
}

/// Diagnostic: per query kind, how separable are on-topic from off-topic by raw
/// distance? Prints mean top-1 distance and the gap/ratio between the best
/// candidate and the candidate median — the signals a calibrated gate could use.
func dumpDistances(store: MemoryStore, querySet: QuerySet) async throws {
    print("\n── distance separability by query kind ──")
    print("kind       n   top1   median   gap(med-top1)   ratio(top1/med)")
    var byKind: [String: [(top1: Double, median: Double)]] = [:]
    for query in querySet.queries {
        let results = (try? await store.fetch(query: query.prompt, limit: 8, recordAccess: false)) ?? []
        let distances = results.map(\.distance).filter { $0.isFinite && $0 < .greatestFiniteMagnitude }
        guard let top1 = distances.min(), !distances.isEmpty else { continue }
        let median = RecallGate.medianDistance(results)
        byKind[query.kind, default: []].append((top1, median))
    }
    for kind in ["targeted", "multi", "negative"] {
        guard let rows = byKind[kind], !rows.isEmpty else { continue }
        let n = Double(rows.count)
        let meanTop1 = rows.map(\.top1).reduce(0, +) / n
        let meanMedian = rows.map(\.median).reduce(0, +) / n
        let meanGap = rows.map { $0.median - $0.top1 }.reduce(0, +) / n
        let meanRatio = rows.map { $0.median > 0 ? $0.top1 / $0.median : 0 }.reduce(0, +) / n
        print(String(format: "%-9@ %3d  %.3f   %.3f   %+.3f          %.3f",
                     kind as NSString, rows.count, meanTop1, meanMedian, meanGap, meanRatio))
    }
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// Session-aware injection report (ADR 0023): the same memory re-injected across
/// an on-topic session, before vs after the cooldown.
func printSessionTable(_ record: SessionRunRecord) {
    let before = record.withoutCooldown
    let after = record.withCooldown
    print("\n── session-aware injection (ADR 0023): \(before.sessionCount) sessions · \(before.promptCount) prompts ──")
    let cols = ["variant", "injections", "redundant", "redund-rate"]
    let widths = [18, 11, 10, 11]
    print(zip(cols, widths).map { pad($0, $1) }.joined(separator: " "))
    let rows = [("no-cooldown", before), ("session-cooldown", after)]
    for (name, r) in rows {
        let cells = [
            pad(name, widths[0]),
            pad("\(r.totalInjections)", widths[1]),
            pad("\(r.redundantInjections)", widths[2]),
            pad(String(format: "%.0f%%", r.redundantRate * 100), widths[3]),
        ]
        print(cells.joined(separator: " "))
    }
    print(String(format: "first-touch coverage: %.0f%%  (memories still surfaced ≥1× — must be 100%%)",
                 record.firstTouchCoverage * 100))
    print("""

    redundant     injections of a memory beyond its first in the same session (repetition)
    redund-rate   redundant ÷ total injections — the session cooldown should drive this to ~0
    coverage      memories injected without the cooldown that still appear with it (over-suppression guard)
    """)
}

func printTable(_ outcomesByConfig: [String: [QueryOutcome]]) {
    let cols = ["variant", "Recall@3", "answer%", "inj-rec", "P@3", "neg-FP%", "neg-junk", "inj-prec"]
    let widths = [16, 9, 8, 8, 7, 8, 9, 9]
    let header = zip(cols, widths).map { pad($0, $1) }.joined(separator: " ")
    print(header)
    print(String(repeating: "─", count: header.count))
    for (name, _) in configs {
        guard let outcomes = outcomesByConfig[name] else { continue }
        let r = RetrievalMetrics.evaluate(outcomes, k: 3)
        let cells = [
            pad(name, widths[0]),
            pad(String(format: "%.3f", r.recallAtK), widths[1]),
            pad(String(format: "%.0f%%", r.answerHitRate * 100), widths[2]),
            pad(String(format: "%.3f", r.injectedRecall), widths[3]),
            pad(String(format: "%.3f", r.precisionAtK), widths[4]),
            pad(String(format: "%.0f%%", r.negativeFalsePositiveRate * 100), widths[5]),
            pad(String(format: "%.2f", r.avgInjectedOnNegatives), widths[6]),
            pad(String(format: "%.3f", r.injectionPrecision), widths[7]),
        ]
        print(cells.joined(separator: " "))
    }
    print("""

    Recall@3  fraction of relevant memories retrieved in the top 3 (pre-gate ceiling)
    answer%   labeled prompts where ≥1 relevant memory survived the gate (gate recall)
    inj-rec   mean fraction of a prompt's relevant memories that got injected
    P@3       precision of what the gate actually injected (labeled queries)
    neg-FP%   negative prompts that wrongly injected ≥1 memory (lower better)
    neg-junk  avg memories injected per negative prompt (lower better)
    inj-prec  relevant ÷ total injected across all prompts (the headline)
    """)
}

try await run()
