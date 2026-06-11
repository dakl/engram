import Foundation

/// Decides which fetched memories are confident enough to inject as advisory
/// context on a user prompt. The recall hook runs on *every* prompt, so the gate
/// is what keeps off-topic memories (and their token cost) out — most prompts
/// should pass nothing through.
///
/// Pulled out of the hook so the hook and the offline retrieval eval
/// (`engram-eval`) score the exact same logic, and so the thresholds are
/// unit-testable without a live store.
public struct RecallGateConfig: Sendable, Equatable {
    /// Maximum memories injected, after filtering.
    public var topK: Int
    /// Floor on the fused relevance signal (RRF-normalized, 0–1). 0 disables.
    public var minRelevance: Double
    /// A memory passes the semantic leg when its cosine distance is below this.
    public var maxDistance: Double
    /// A memory passes the lexical leg when it shares at least this many distinct
    /// query tokens. 1 ≈ "any shared keyword" (today's behavior); ≥2 demands real
    /// vocabulary overlap. 0 disables the lexical leg entirely.
    public var minLexicalTokenHits: Int
    /// When true, the semantic ceiling is tightened to the *candidate-set median*
    /// distance — a memory must stand out from the background, which adapts to a
    /// weak embedder instead of trusting an absolute threshold.
    public var requireDistanceBelowMedian: Bool

    public init(
        topK: Int = 3,
        minRelevance: Double = 0,
        maxDistance: Double = 0.45,
        minLexicalTokenHits: Int = 1,
        requireDistanceBelowMedian: Bool = false
    ) {
        self.topK = topK
        self.minRelevance = minRelevance
        self.maxDistance = maxDistance
        self.minLexicalTokenHits = minLexicalTokenHits
        self.requireDistanceBelowMedian = requireDistanceBelowMedian
    }

    /// Today's shipped gate: any single lexical keyword hit OR a tight-ish
    /// absolute distance, top 3. The eval's baseline.
    public static let current = RecallGateConfig(
        topK: 3,
        minRelevance: 0,
        maxDistance: 0.45,
        minLexicalTokenHits: 1,
        requireDistanceBelowMedian: false
    )

    /// Tightened gate, calibrated from the `engram-eval` sweep: a distance ceiling
    /// at the embedder's *actual* scale (contextual distances cluster near ~0.1,
    /// so 0.45 was a no-op), and a lexical leg that demands ≥2 shared tokens to
    /// kill the single-keyword leak. The per-query relevance floor and median gate
    /// were dropped — measurement showed neither separates on- from off-topic.
    ///
    /// ⚠️ `maxDistance` is embedder-specific. 0.10 fits the contextual model; the
    /// fallback `word-512` embedder lives on a different scale. Before shipping to
    /// the hook this should become embedder-relative rather than a constant.
    public static let proposed = RecallGateConfig(
        topK: 3,
        minRelevance: 0,
        maxDistance: 0.10,
        minLexicalTokenHits: 2,
        requireDistanceBelowMedian: false
    )

    /// Control: semantic-only with a strict absolute distance, no lexical leg.
    public static let strictSemantic = RecallGateConfig(
        topK: 3,
        minRelevance: 0,
        maxDistance: 0.35,
        minLexicalTokenHits: 0,
        requireDistanceBelowMedian: false
    )
}

public enum RecallGate {
    /// The gate calibrated for a given embedder, keyed off `Embedder.signature`.
    /// Distance thresholds are embedder-specific — the contextual model clusters
    /// near ~0.1, the static `word-512` fallback lives on a different scale — so
    /// the ceiling can't be one global constant (see ADR 0021).
    ///
    /// The fallback embedder is a transient, degraded state (one launch until
    /// contextual assets download); rather than risk gating everything out on a
    /// scale we haven't calibrated, it keeps the older permissive behavior.
    public static func config(forEmbedderSignature signature: String) -> RecallGateConfig {
        if signature.hasPrefix("contextual") {
            return .proposed
        }
        return .current
    }

    /// Filters fetched results down to the confident ones to inject.
    ///
    /// `results` are expected best-first (as `MemoryStore.fetch` returns them).
    /// `query` is the user's prompt — needed to recompute lexical token overlap.
    public static func select(
        _ results: [ScoredMemory],
        query: String,
        config: RecallGateConfig
    ) -> [ScoredMemory] {
        guard !results.isEmpty else { return [] }

        let distanceCeiling = config.requireDistanceBelowMedian
            ? min(config.maxDistance, medianDistance(results))
            : config.maxDistance

        let passing = results.filter { result in
            guard result.relevance >= config.minRelevance else { return false }
            let semanticPass = result.distance < distanceCeiling
            let lexicalPass = config.minLexicalTokenHits > 0
                && RecallText.lexicalTokenHits(query: query, in: lexicalText(result.memory))
                    >= config.minLexicalTokenHits
            return semanticPass || lexicalPass
        }
        return Array(passing.prefix(config.topK))
    }

    /// Median of the real candidate distances. Lexical-only candidates carry no
    /// distance (the `greatestFiniteMagnitude` sentinel) and are excluded so they
    /// don't drag the median up. Falls back to that sentinel when none are real.
    public static func medianDistance(_ results: [ScoredMemory]) -> Double {
        let finite = results.map(\.distance)
            .filter { $0.isFinite && $0 < .greatestFiniteMagnitude }
            .sorted()
        guard !finite.isEmpty else { return .greatestFiniteMagnitude }
        let mid = finite.count / 2
        return finite.count.isMultiple(of: 2)
            ? (finite[mid - 1] + finite[mid]) / 2
            : finite[mid]
    }

    /// The text the lexical (FTS5) stage indexes: content + tags. Title is
    /// excluded to mirror what `insertFTS` stores.
    private static func lexicalText(_ memory: Memory) -> String {
        (memory.tags + [memory.content]).joined(separator: " ")
    }
}
