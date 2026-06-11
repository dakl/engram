import Foundation
import Testing
@testable import EngramCore

private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

@Test func recallAtKCountsRelevantInTopK() {
    let outcome = QueryOutcome(relevant: [a, b], ranked: [a, c, b, d], injected: [])
    // Both relevant are within top 3.
    #expect(RetrievalMetrics.recallAtK(outcome, k: 3) == 1.0)
    // Only `a` is within top 2.
    #expect(RetrievalMetrics.recallAtK(outcome, k: 2) == 0.5)
}

@Test func reciprocalRankUsesFirstRelevant() {
    let outcome = QueryOutcome(relevant: [b], ranked: [a, b, c], injected: [])
    #expect(RetrievalMetrics.reciprocalRank(outcome) == 1.0 / 2.0)
}

@Test func reciprocalRankZeroWhenAbsent() {
    let outcome = QueryOutcome(relevant: [d], ranked: [a, b, c], injected: [])
    #expect(RetrievalMetrics.reciprocalRank(outcome) == 0)
}

@Test func precisionOfInjectedIsHitsOverShown() {
    let outcome = QueryOutcome(relevant: [a], ranked: [a, b], injected: [a, b])
    #expect(RetrievalMetrics.precisionOfInjected(outcome) == 0.5)
}

@Test func negativeFalsePositiveRateAndJunk() {
    let outcomes = [
        QueryOutcome(relevant: [], ranked: [a], injected: [a]),       // wrongly injected
        QueryOutcome(relevant: [], ranked: [b], injected: []),        // correctly silent
        QueryOutcome(relevant: [a], ranked: [a], injected: [a]),      // labeled, ignored by neg metrics
    ]
    let report = RetrievalMetrics.evaluate(outcomes, k: 3)
    #expect(report.negativeCount == 2)
    #expect(report.negativeFalsePositiveRate == 0.5)
    #expect(report.avgInjectedOnNegatives == 0.5)
}

@Test func injectionPrecisionSpansAllQueries() {
    let outcomes = [
        QueryOutcome(relevant: [a], ranked: [a], injected: [a]),      // 1 relevant injected
        QueryOutcome(relevant: [], ranked: [b], injected: [b]),       // 1 junk injected
    ]
    let report = RetrievalMetrics.evaluate(outcomes, k: 3)
    // 1 relevant of 2 injected.
    #expect(report.injectionPrecision == 0.5)
}

@Test func injectionPrecisionIsOneWhenNothingInjected() {
    let outcomes = [QueryOutcome(relevant: [a], ranked: [a], injected: [])]
    let report = RetrievalMetrics.evaluate(outcomes, k: 3)
    #expect(report.injectionPrecision == 1.0)
}

@Test func perfectRunScoresTopMarks() {
    let outcomes = [
        QueryOutcome(relevant: [a], ranked: [a, b], injected: [a]),
        QueryOutcome(relevant: [b], ranked: [b, c], injected: [b]),
        QueryOutcome(relevant: [], ranked: [d], injected: []),
    ]
    let report = RetrievalMetrics.evaluate(outcomes, k: 3)
    #expect(report.recallAtK == 1.0)
    #expect(report.mrr == 1.0)
    #expect(report.precisionAtK == 1.0)
    #expect(report.negativeFalsePositiveRate == 0)
    #expect(report.injectionPrecision == 1.0)
    #expect(report.labeledCount == 2)
}
