import Foundation

/// The outcome of a cheap, deterministic (non-LLM) check on a single memory.
public enum Verdict: String, Sendable {
    case confirmed
    case contradicted
    case stale
    case inconclusive
}

/// A verdict for one memory, with a short human-readable reason.
public struct MemoryVerdict: Sendable {
    public let id: UUID
    public let verdict: Verdict
    public let reason: String

    public init(id: UUID, verdict: Verdict, reason: String) {
        self.id = id
        self.verdict = verdict
        self.reason = reason
    }
}

/// Cheap deterministic verification (ADR 0008, Phase 2 — scoped). No LLM, no
/// network. Pure and DB-free so callers inject `repoRoot`, `fileExists`, and
/// `now`; `MemoryStore` wires those to the real filesystem and clock.
public enum Verifier {
    /// Memories older than this (by `as of` date) are flagged `stale`.
    private static let staleThreshold: TimeInterval = 90 * 24 * 3600

    /// Parses the `as of YYYY-MM-DD` date marker (UTC), if present.
    private static let asOfDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Matches an `as of YYYY-MM-DD` marker in the content.
    private static let asOfRegex = try! NSRegularExpression(
        pattern: #"as of (\d{4}-\d{2}-\d{2})"#,
        options: [.caseInsensitive]
    )

    /// Decides a verdict for `memory`, in precedence order:
    /// 1. non-auto-verifiable class → `inconclusive`
    /// 2. `checkAnchor` is `branch:<name>` → branch present `confirmed` / gone `stale`
    /// 3. `checkAnchor` is a file path + repo root exists → file present/missing
    /// 4. `as of` date older than 90 days → `stale`
    /// 5. otherwise → `inconclusive`
    ///
    /// Deterministic `verify` covers file-existence, git-branch liveness, and age
    /// — all local and LLM-free. Two checks are intentionally OUT of scope here:
    /// PR-liveness (requires a network call to the forge) and conflict-pair
    /// detection (high embedding similarity + contradictory content, which needs
    /// an LLM to judge). Conflict detection is handled by `/dream`'s LLM
    /// falsification escalation (ADR 0008), not by this deterministic path.
    public static func verdict(
        for memory: Memory,
        repoRoot: URL?,
        fileExists: (URL) -> Bool,
        branchExists: (String) -> Bool,
        now: Date
    ) -> MemoryVerdict {
        if memory.verifiability == .userConfirmOnly || memory.verifiability == .timeless {
            return MemoryVerdict(id: memory.id, verdict: .inconclusive,
                                 reason: "not auto-verifiable (\(memory.verifiability.rawValue))")
        }

        if let anchor = memory.checkAnchor, anchor.hasPrefix("branch:") {
            let name = String(anchor.dropFirst("branch:".count))
            if branchExists(name) {
                return MemoryVerdict(id: memory.id, verdict: .confirmed,
                                     reason: "branch \(name) exists")
            }
            return MemoryVerdict(id: memory.id, verdict: .stale,
                                 reason: "branch \(name) not found — merged/deleted")
        }

        if let anchor = memory.checkAnchor, looksLikeFilePath(anchor) {
            guard let repoRoot, fileExists(repoRoot) else {
                return MemoryVerdict(id: memory.id, verdict: .inconclusive,
                                     reason: "repo root for source missing")
            }
            let fileURL = repoRoot.appendingPathComponent(anchor)
            if fileExists(fileURL) {
                return MemoryVerdict(id: memory.id, verdict: .confirmed,
                                     reason: "checkAnchor file exists: \(anchor)")
            }
            return MemoryVerdict(id: memory.id, verdict: .contradicted,
                                 reason: "checkAnchor file missing: \(anchor)")
        }

        if let asOf = asOfDate(in: memory.content),
           now.timeIntervalSince(asOf) > staleThreshold {
            return MemoryVerdict(id: memory.id, verdict: .stale,
                                 reason: "as-of date older than 90 days")
        }

        return MemoryVerdict(id: memory.id, verdict: .inconclusive, reason: "no cheap check applied")
    }

    /// A `checkAnchor` looks like a file path if it has no spaces and contains a
    /// path separator or a file extension.
    private static func looksLikeFilePath(_ anchor: String) -> Bool {
        guard !anchor.contains(" ") else { return false }
        if anchor.contains("/") { return true }
        let ext = (anchor as NSString).pathExtension
        return !ext.isEmpty
    }

    /// Extracts the date from an `as of YYYY-MM-DD` marker, if parseable.
    private static func asOfDate(in content: String) -> Date? {
        let range = NSRange(content.startIndex..., in: content)
        guard
            let match = asOfRegex.firstMatch(in: content, range: range),
            let dateRange = Range(match.range(at: 1), in: content)
        else { return nil }
        return asOfDateFormatter.date(from: String(content[dateRange]))
    }
}
