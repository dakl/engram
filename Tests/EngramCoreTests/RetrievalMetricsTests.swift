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

@Test func sessionMetricCountsRedundantReinjections() {
    // Two sessions. Session 1 injects A on three prompts (2 redundant) and B once;
    // session 2 injects A once. Total 5 injections, 2 redundant → 40%.
    let sessions: [[[UUID]]] = [
        [[a], [a, b], [a]],
        [[a]],
    ]
    let report = RetrievalMetrics.evaluateSessions(sessions)
    #expect(report.sessionCount == 2)
    #expect(report.promptCount == 4)
    #expect(report.totalInjections == 5)
    #expect(report.redundantInjections == 2)
    #expect(abs(report.redundantRate - 0.4) < 1e-9)
}

@Test func sessionMetricZeroWhenNoRepeats() {
    let sessions: [[[UUID]]] = [[[a], [b], [c]]]
    let report = RetrievalMetrics.evaluateSessions(sessions)
    #expect(report.redundantInjections == 0)
    #expect(report.redundantRate == 0)
}

@Test func firstTouchCoverageIsFullWhenCooldownOnlyDropsRepeats() {
    // Without cooldown A appears twice + B once; with cooldown A once + B once.
    // Every distinct memory still surfaced → coverage 1.0.
    let without: [[[UUID]]] = [[[a], [a, b]]]
    let withCd: [[[UUID]]] = [[[a], [b]]]
    #expect(RetrievalMetrics.firstTouchCoverage(withoutCooldown: without, withCooldown: withCd) == 1.0)
    // If the cooldown wrongly dropped B entirely, coverage falls to 0.5.
    let dropped: [[[UUID]]] = [[[a], []]]
    #expect(RetrievalMetrics.firstTouchCoverage(withoutCooldown: without, withCooldown: dropped) == 0.5)
}
