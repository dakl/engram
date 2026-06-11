import Foundation

/// One query's ground truth plus what retrieval and the gate actually did with
/// it. Pure data so metrics can be computed (and tested) without a live store.
public struct QueryOutcome: Sendable {
    /// The memory ids that *should* surface. Empty for a negative ("should inject
    /// nothing") query.
    public let relevant: Set<UUID>
    /// The full ranked candidate list (pre-gate), best-first. Measures the
    /// retrieval ceiling independent of the gate.
    public let ranked: [UUID]
    /// The ids the gate actually selected for injection.
    public let injected: [UUID]

    public init(relevant: Set<UUID>, ranked: [UUID], injected: [UUID]) {
        self.relevant = relevant
        self.ranked = ranked
        self.injected = injected
    }

    var isNegative: Bool { relevant.isEmpty }
}

/// Aggregate retrieval quality for one gate configuration over a query set.
public struct RetrievalReport: Sendable, Codable {
    /// Mean Recall@k over labeled queries: fraction of each query's relevant set
    /// found in the top-k retrieved candidates (pre-gate ceiling).
    public let recallAtK: Double
    /// Mean Reciprocal Rank over labeled queries (first relevant in `ranked`).
    public let mrr: Double
    /// Mean Precision@k of the *injected* set over labeled queries with any
    /// injection — of what we showed, how much was right.
    public let precisionAtK: Double
    /// Mean fraction of each labeled query's relevant set that survived the gate
    /// and was actually injected. The gate's recall — what tightening costs.
    public let injectedRecall: Double
    /// Fraction of labeled queries where at least one relevant memory was
    /// injected. "Did the right note get through at all?"
    public let answerHitRate: Double
    /// Fraction of negative queries that wrongly injected ≥1 memory. The headline
    /// false-positive number — lower is better.
    public let negativeFalsePositiveRate: Double
    /// Mean count of memories injected on negative queries (junk per off-topic
    /// prompt).
    public let avgInjectedOnNegatives: Double
    /// Across *all* queries: relevant injected ÷ total injected. Negatives only
    /// add to the denominator, so this captures the whole precision/noise story
    /// in one number.
    public let injectionPrecision: Double
    public let labeledCount: Int
    public let negativeCount: Int
}

public enum RetrievalMetrics {
    public static func evaluate(_ outcomes: [QueryOutcome], k: Int) -> RetrievalReport {
        let labeled = outcomes.filter { !$0.isNegative }
        let negatives = outcomes.filter(\.isNegative)

        let recall = mean(labeled.map { recallAtK($0, k: k) })
        let mrr = mean(labeled.map(reciprocalRank))

        let withInjection = labeled.filter { !$0.injected.isEmpty }
        let precision = mean(withInjection.map { precisionOfInjected($0) })
        let meanInjectedRecall = mean(labeled.map { injectedRecall($0) })
        let answerHitRate = labeled.isEmpty
            ? 0
            : Double(labeled.filter { !$0.injected.filter($0.relevant.contains).isEmpty }.count) / Double(labeled.count)

        let negativeFPR = negatives.isEmpty
            ? 0
            : Double(negatives.filter { !$0.injected.isEmpty }.count) / Double(negatives.count)
        let avgNegInjected = mean(negatives.map { Double($0.injected.count) })

        let totalInjected = outcomes.reduce(0) { $0 + $1.injected.count }
        let relevantInjected = outcomes.reduce(0) { sum, outcome in
            sum + outcome.injected.filter(outcome.relevant.contains).count
        }
        let injectionPrecision = totalInjected == 0 ? 1 : Double(relevantInjected) / Double(totalInjected)

        return RetrievalReport(
            recallAtK: recall,
            mrr: mrr,
            precisionAtK: precision,
            injectedRecall: meanInjectedRecall,
            answerHitRate: answerHitRate,
            negativeFalsePositiveRate: negativeFPR,
            avgInjectedOnNegatives: avgNegInjected,
            injectionPrecision: injectionPrecision,
            labeledCount: labeled.count,
            negativeCount: negatives.count
        )
    }

    static func recallAtK(_ outcome: QueryOutcome, k: Int) -> Double {
        guard !outcome.relevant.isEmpty else { return 0 }
        let topK = outcome.ranked.prefix(k)
        let found = topK.filter(outcome.relevant.contains).count
        return Double(found) / Double(outcome.relevant.count)
    }

    static func reciprocalRank(_ outcome: QueryOutcome) -> Double {
        for (index, id) in outcome.ranked.enumerated() where outcome.relevant.contains(id) {
            return 1.0 / Double(index + 1)
        }
        return 0
    }

    static func precisionOfInjected(_ outcome: QueryOutcome) -> Double {
        guard !outcome.injected.isEmpty else { return 0 }
        let hits = outcome.injected.filter(outcome.relevant.contains).count
        return Double(hits) / Double(outcome.injected.count)
    }

    static func injectedRecall(_ outcome: QueryOutcome) -> Double {
        guard !outcome.relevant.isEmpty else { return 0 }
        let hits = outcome.injected.filter(outcome.relevant.contains).count
        return Double(hits) / Double(outcome.relevant.count)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
