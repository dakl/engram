import Foundation

/// Tunable weights for the blended relevance score.
public struct RankingConfig: Sendable {
    /// Weight of the retrieval relevance signal (fused lexical + semantic).
    public var relevanceWeight: Double
    public var recencyWeight: Double
    public var frequencyWeight: Double
    /// A memory last touched this many days ago scores 0.5 on recency.
    public var recencyHalfLifeDays: Double

    public init(
        relevanceWeight: Double = 0.70,
        recencyWeight: Double = 0.20,
        frequencyWeight: Double = 0.10,
        recencyHalfLifeDays: Double = 30.0
    ) {
        self.relevanceWeight = relevanceWeight
        self.recencyWeight = recencyWeight
        self.frequencyWeight = frequencyWeight
        self.recencyHalfLifeDays = recencyHalfLifeDays
    }

    public static let `default` = RankingConfig()
}

/// Blends a retrieval relevance signal with recency and usage to order results.
///
/// Relevance alone ignores that a memory touched yesterday and used 40 times is
/// usually more useful than a slightly-closer one from a year ago that's never
/// been read. `score` combines the three signals; higher wins.
public enum Ranking {
    /// - Parameter relevance: fused lexical+semantic relevance, normalized to 0–1.
    public static func score(
        relevance: Double,
        memory: Memory,
        now: Date = Date(),
        config: RankingConfig = .default
    ) -> Double {
        // Exponential decay on time since last touch (fall back to creation).
        let referenceDate = memory.lastAccessedAt ?? memory.createdAt
        let ageDays = max(0, now.timeIntervalSince(referenceDate) / 86_400)
        let recency = pow(0.5, ageDays / config.recencyHalfLifeDays)

        // Diminishing returns on access count via log scaling.
        let frequency = min(1, log1p(Double(memory.accessCount)) / log1p(50))

        return config.relevanceWeight * max(0, min(1, relevance))
            + config.recencyWeight * recency
            + config.frequencyWeight * frequency
    }

    /// How fast a memory's truth decays once verified, by class (ADR 0008).
    /// `userConfirmOnly`/`timeless` are 0 — they're excluded from auto-verification
    /// and so carry no machine-checkable rot risk.
    static func volatility(_ verifiability: Verifiability) -> Double {
        switch verifiability {
        case .projectState: return 1.0
        case .codeGrounded: return 0.8
        case .configInfra: return 0.6
        case .decision: return 0.3
        case .userConfirmOnly, .timeless: return 0.0
        }
    }

    /// Rot-risk score: how likely a memory has gone stale and warrants a re-check
    /// (ADR 0008). Higher = riskier. Drives `engram list --by-risk` and ordering of
    /// auto-verification candidates.
    ///
    ///   risk = daysSinceVerified × volatility × verifiable × importance
    ///
    /// - `daysSinceVerified`: time since last verification (or creation if never
    ///   verified) — staleness grows with time.
    /// - `volatility`: per-class decay rate (see `volatility(_:)`).
    /// - `verifiable`: 0 for `userConfirmOnly`/`timeless` (can't be auto-checked),
    ///   1 otherwise — forces those classes to score 0.
    /// - `importance`: `1 + log1p(accessCount)` — a stale-but-unused memory matters
    ///   less than a stale-and-frequently-read one.
    public static func rotRisk(for memory: Memory, now: Date = Date()) -> Double {
        let verifiable = (memory.verifiability == .userConfirmOnly || memory.verifiability == .timeless) ? 0.0 : 1.0
        let referenceDate = memory.verifiedAt ?? memory.createdAt
        let daysSinceVerified = max(0, now.timeIntervalSince(referenceDate) / 86_400)
        let importance = 1 + log1p(Double(memory.accessCount))
        return daysSinceVerified * volatility(memory.verifiability) * verifiable * importance
    }
}
