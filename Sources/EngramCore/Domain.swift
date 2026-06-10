import Foundation

/// How (and whether) a memory can be machine-checked for freshness. See
/// ADR 0008: drives the rot-risk score and which memories `/dream` verifies.
public enum Verifiability: String, Sendable, CaseIterable {
    case codeGrounded
    case configInfra
    case decision
    case projectState
    case userConfirmOnly
    case timeless
}

/// A single stored memory. Field set is deliberately sync-friendly:
/// stable UUID, distinct create/update/access timestamps, and a soft-delete
/// marker so a future CloudKit mirror can diff and tombstone cleanly.
public struct Memory: Identifiable, Sendable, Hashable {
    public let id: UUID
    /// Optional one-line display label, model-written at store time (ADR 0014).
    /// Decoupled from `content`; the UI falls back to the first content line when nil.
    public var title: String?
    public var content: String
    public var tags: [String]
    /// Origin of the memory, e.g. a repo or project name. Optional.
    public var source: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var lastAccessedAt: Date?
    public var accessCount: Int
    public var deletedAt: Date?
    /// Verification fields (ADR 0008).
    public var verifiability: Verifiability
    /// File path / grep / command / query that confirms-or-refutes the memory.
    public var checkAnchor: String?
    public var verifiedAt: Date?
    public var confidence: Double
    public var supersededBy: UUID?
    public var evolutionReason: String?

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        content: String,
        tags: [String] = [],
        source: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        accessCount: Int = 0,
        deletedAt: Date? = nil,
        verifiability: Verifiability = .userConfirmOnly,
        checkAnchor: String? = nil,
        verifiedAt: Date? = nil,
        confidence: Double = 1.0,
        supersededBy: UUID? = nil,
        evolutionReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
        self.deletedAt = deletedAt
        self.verifiability = verifiability
        self.checkAnchor = checkAnchor
        self.verifiedAt = verifiedAt
        self.confidence = confidence
        self.supersededBy = supersededBy
        self.evolutionReason = evolutionReason
    }

    /// One-line label for lists. The authored `title` when present, otherwise a
    /// fallback derived from the content's first non-empty line (ADR 0014),
    /// stripping a leading Markdown `#` heading marker.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title.trimmingCharacters(in: .whitespaces)
        }
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return firstLine
            .drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A memory returned from hybrid search, with the signals used to rank and gate
/// it: vector `distance` (smaller = closer; `.greatestFiniteMagnitude` if it
/// wasn't a vector hit), whether it matched the lexical query, the fused
/// `relevance` (0–1), and the final blended `score`.
public struct ScoredMemory: Identifiable, Sendable {
    public var memory: Memory
    public var distance: Double
    public var lexicalMatch: Bool
    public var relevance: Double
    public var score: Double
    public var id: UUID { memory.id }

    public init(memory: Memory, distance: Double, lexicalMatch: Bool, relevance: Double, score: Double) {
        self.memory = memory
        self.distance = distance
        self.lexicalMatch = lexicalMatch
        self.relevance = relevance
        self.score = score
    }
}

/// Lifecycle events, recorded per occurrence so analytics can show how many
/// memories were created/accessed/updated/deleted over a time window.
public enum EventKind: String, Sendable, CaseIterable {
    case created
    case accessed
    case updated
    case deleted
}

/// How a memory was retrieved. Recorded per occurrence in the `retrievals`
/// ledger (ADR 0015) — decoupled from `accessCount`/ranking. The three hook
/// sources mirror the `engram hook` subcommands.
public enum RetrievalSource: String, Sendable, CaseIterable {
    case recall
    case sessionDigest = "session-digest"
    case verifyContext = "verify-context"
    case fetch
    case search

    /// Stable hue index (0…4, one per case) into the shared community palette, so
    /// the source→color mapping lives in the domain and reads the same everywhere
    /// (ADR 0017).
    public var colorIndex: Int {
        switch self {
        case .recall: return 0
        case .sessionDigest: return 1
        case .verifyContext: return 2
        case .fetch: return 3
        case .search: return 4
        }
    }
}

/// One row of the retrieval-activity ledger (ADR 0015): a memory that was
/// surfaced at a point in time, via which `source`, optionally with the query
/// that surfaced it.
public struct RetrievalEvent: Sendable, Identifiable {
    public let id: Int
    public let memoryID: UUID
    public let source: RetrievalSource
    public let query: String?
    public let at: Date

    public init(id: Int, memoryID: UUID, source: RetrievalSource, query: String?, at: Date) {
        self.id = id
        self.memoryID = memoryID
        self.source = source
        self.query = query
        self.at = at
    }
}

/// What happened to a memory at a point in time — the union of retrieval sources
/// (reads) and lifecycle writes — backing the unified Activity timeline (ADR 0020).
/// The display authority for an activity row: it owns the badge label, palette hue,
/// and read/write split. `RetrievalSource` stays the *recording* type (ADR 0015);
/// the read-case raw values are kept aligned so the two map losslessly.
public enum ActivityKind: String, Sendable, CaseIterable {
    // Reads (raw values mirror `RetrievalSource`).
    case recall
    case sessionDigest = "session-digest"
    case verifyContext = "verify-context"
    case fetch
    case search
    // Writes — verbs, not the lifecycle past-participles, so the badge and the
    // CLI `--source` token agree (`store`/`update`/`delete`). Mapped from
    // `EventKind` in `init(event:)`; `accessed` is deliberately excluded.
    case store
    case update
    case delete

    /// Writes change the store; reads surface existing memories.
    public var isWrite: Bool {
        switch self {
        case .store, .update, .delete: return true
        default: return false
        }
    }

    /// Uppercase badge label — the raw value reads as the action verb directly.
    public var label: String { rawValue.uppercased() }

    /// Stable hue index into the shared community palette — reads keep ADR 0015's
    /// 0…4; writes take 5…7 so they read as a distinct family.
    public var colorIndex: Int {
        switch self {
        case .recall: return 0
        case .sessionDigest: return 1
        case .verifyContext: return 2
        case .fetch: return 3
        case .search: return 4
        case .store: return 5
        case .update: return 6
        case .delete: return 7
        }
    }

    /// A read activity from how it was recorded; read raw values are aligned by design.
    public init(retrieval: RetrievalSource) {
        self = ActivityKind(rawValue: retrieval.rawValue) ?? .recall
    }

    /// A write activity from a lifecycle event; `nil` for `.accessed`, which
    /// overlaps the retrievals ledger and is excluded from the timeline (ADR 0020).
    public init?(event: EventKind) {
        switch event {
        case .created: self = .store
        case .updated: self = .update
        case .deleted: self = .delete
        case .accessed: return nil
        }
    }
}

/// One row of the unified Activity timeline (ADR 0020): a memory touched at a point
/// in time, via which `kind`, with the `query` that surfaced it for read kinds
/// (`nil` for writes). `id` is ledger-prefixed (`r:`/`e:`) to stay unique across the
/// two source tables.
public struct ActivityEvent: Sendable, Identifiable, Equatable {
    public let id: String
    public let memoryID: UUID
    public let kind: ActivityKind
    public let query: String?
    public let at: Date

    public init(id: String, memoryID: UUID, kind: ActivityKind, query: String?, at: Date) {
        self.id = id
        self.memoryID = memoryID
        self.kind = kind
        self.query = query
        self.at = at
    }
}

/// A retrieval-activity lookback window. The presets back the app's segmented
/// control; `parse` powers the CLI's `--since` flag and accepts any `<n><unit>`.
public enum Lookback: String, Sendable, CaseIterable {
    case m15 = "15m"
    case h1 = "1h"
    case h6 = "6h"
    case d1 = "1d"

    public var interval: TimeInterval {
        switch self {
        case .m15: return 15 * 60
        case .h1: return 3600
        case .h6: return 6 * 3600
        case .d1: return 24 * 3600
        }
    }

    /// Parses a duration like `15m`, `1h`, `6h`, `1d` into seconds. Returns nil
    /// for malformed or non-positive input.
    public static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let value = Int(trimmed.dropLast()), value > 0 else { return nil }
        switch unit {
        case "m": return Double(value) * 60
        case "h": return Double(value) * 3600
        case "d": return Double(value) * 24 * 3600
        default: return nil
        }
    }
}

/// Aggregate counts for the main window's stats panel.
public struct MemoryStats: Sendable, Equatable {
    public var totalActive: Int
    public var totalDeleted: Int
    public var createdLast7Days: Int
    public var accessedLast7Days: Int
    public var totalAccesses: Int
    public var databaseBytes: Int64
    public var topTags: [(tag: String, count: Int)]

    public init(
        totalActive: Int = 0,
        totalDeleted: Int = 0,
        createdLast7Days: Int = 0,
        accessedLast7Days: Int = 0,
        totalAccesses: Int = 0,
        databaseBytes: Int64 = 0,
        topTags: [(tag: String, count: Int)] = []
    ) {
        self.totalActive = totalActive
        self.totalDeleted = totalDeleted
        self.createdLast7Days = createdLast7Days
        self.accessedLast7Days = accessedLast7Days
        self.totalAccesses = totalAccesses
        self.databaseBytes = databaseBytes
        self.topTags = topTags
    }

    public static func == (lhs: MemoryStats, rhs: MemoryStats) -> Bool {
        // `topTags` is a tuple array, which blocks synthesized Equatable, so the
        // counters are grouped into a tuple and the tags compared element-wise.
        let lhsCounters = (lhs.totalActive, lhs.totalDeleted, lhs.createdLast7Days, lhs.accessedLast7Days, lhs.totalAccesses, lhs.databaseBytes)
        let rhsCounters = (rhs.totalActive, rhs.totalDeleted, rhs.createdLast7Days, rhs.accessedLast7Days, rhs.totalAccesses, rhs.databaseBytes)
        return lhsCounters == rhsCounters
            && lhs.topTags.map(\.tag) == rhs.topTags.map(\.tag)
            && lhs.topTags.map(\.count) == rhs.topTags.map(\.count)
    }
}

/// On-disk location for the store. The (non-sandboxed) app and the CLI both
/// resolve to the same file under Application Support. Development and
/// production share one store — memories are personal knowledge, not app state.
public enum EngramPaths {
    /// The Engram support directory; created on access. Home to the store and
    /// any small sidecar state (e.g. the per-session reflection-nudge counter).
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Engram", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Personal memories are stored in plaintext, so lock the directory to the
        // owner (0700) — this alone blocks other local accounts from reading the
        // DB and its sidecars regardless of individual file perms. Idempotent;
        // re-applied each access to harden directories created before this.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    public static var defaultDatabaseURL: URL {
        supportDirectory.appendingPathComponent("engram.sqlite")
    }
}
