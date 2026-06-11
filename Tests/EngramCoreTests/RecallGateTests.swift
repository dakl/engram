import Foundation
import Testing
@testable import EngramCore

private func scored(
    content: String,
    tags: [String] = [],
    distance: Double,
    relevance: Double
) -> ScoredMemory {
    ScoredMemory(
        memory: Memory(content: content, tags: tags),
        distance: distance,
        lexicalMatch: false,
        relevance: relevance,
        score: relevance
    )
}

// MARK: - The leak the proposed gate is meant to close

@Test func currentGatePassesOnSingleSharedKeyword() {
    // Prompt shares exactly one non-stopword token ("memory") with an otherwise
    // unrelated memory — today's gate lets it through.
    let results = [scored(content: "Daniel prefers mushrooms on pizza memory", distance: 0.9, relevance: 0.2)]
    let passed = RecallGate.select(results, query: "how does the memory subsystem work", config: .current)
    #expect(passed.count == 1)
}

@Test func proposedGateRejectsSingleSharedKeyword() {
    let results = [scored(content: "Daniel prefers mushrooms on pizza memory", distance: 0.9, relevance: 0.2)]
    let passed = RecallGate.select(results, query: "how does the memory subsystem work", config: .proposed)
    #expect(passed.isEmpty)
}

@Test func proposedGatePassesOnRealOverlap() {
    // Two shared tokens ("memory", "subsystem") and a strong fused relevance.
    let results = [
        scored(content: "the memory subsystem stores embeddings in sqlite-vec", distance: 0.2, relevance: 0.9)
    ]
    let passed = RecallGate.select(results, query: "how does the memory subsystem work", config: .proposed)
    #expect(passed.count == 1)
}

// MARK: - Individual levers

@Test func relevanceFloorFiltersWeakFusedMatches() {
    let cfg = RecallGateConfig(topK: 3, minRelevance: 0.5, maxDistance: 1.0, minLexicalTokenHits: 0)
    let results = [
        scored(content: "strong", distance: 0.1, relevance: 0.8),
        scored(content: "weak", distance: 0.1, relevance: 0.3),
    ]
    let passed = RecallGate.select(results, query: "anything", config: cfg)
    #expect(passed.map(\.memory.content) == ["strong"])
}

@Test func semanticLegPassesBelowDistanceCeiling() {
    let cfg = RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.45, minLexicalTokenHits: 0)
    let results = [
        scored(content: "near", distance: 0.30, relevance: 0.5),
        scored(content: "far", distance: 0.60, relevance: 0.5),
    ]
    let passed = RecallGate.select(results, query: "no shared tokens zzz", config: cfg)
    #expect(passed.map(\.memory.content) == ["near"])
}

@Test func medianGateTightensCeilingToCandidateSpread() {
    // Absolute ceiling is generous (0.45) but the median of {0.1, 0.3, 0.5} is
    // 0.3, so only the 0.1 candidate stays once the median gate is on.
    let cfg = RecallGateConfig(
        topK: 3, minRelevance: 0, maxDistance: 0.45,
        minLexicalTokenHits: 0, requireDistanceBelowMedian: true
    )
    let results = [
        scored(content: "closest", distance: 0.10, relevance: 0.9),
        scored(content: "median", distance: 0.30, relevance: 0.6),
        scored(content: "farther", distance: 0.50, relevance: 0.4),
    ]
    let passed = RecallGate.select(results, query: "zzz", config: cfg)
    #expect(passed.map(\.memory.content) == ["closest"])
}

@Test func topKCapsInjection() {
    let cfg = RecallGateConfig(topK: 2, minRelevance: 0, maxDistance: 1.0, minLexicalTokenHits: 0)
    let results = (0..<5).map { scored(content: "m\($0)", distance: 0.1, relevance: 0.9) }
    #expect(RecallGate.select(results, query: "x", config: cfg).count == 2)
}

@Test func emptyResultsYieldNothing() {
    #expect(RecallGate.select([], query: "x", config: .current).isEmpty)
}

@Test func contextualEmbedderGetsTightenedGate() {
    #expect(RecallGate.config(forEmbedderSignature: "contextual-512") == .proposed)
}

@Test func fallbackEmbedderKeepsPermissiveGate() {
    // Distances on word-512 live on a scale we haven't calibrated; stay loose.
    #expect(RecallGate.config(forEmbedderSignature: "word-512") == .current)
}

@Test func medianIgnoresNonFiniteDistances() {
    let results = [
        scored(content: "a", distance: 0.2, relevance: 1),
        scored(content: "b", distance: 0.4, relevance: 1),
        scored(content: "lexical-only", distance: .greatestFiniteMagnitude, relevance: 1),
    ]
    // Median of the two real distances {0.2, 0.4} = 0.3, not skewed by the sentinel.
    #expect(abs(RecallGate.medianDistance(results) - 0.3) < 1e-9)
}

@Test func tagsCountTowardLexicalOverlap() {
    // Shared tokens live in tags, not content.
    let cfg = RecallGateConfig(topK: 3, minRelevance: 0, maxDistance: 0.0, minLexicalTokenHits: 2)
    let results = [scored(content: "unrelated text", tags: ["billing", "invoices"], distance: 0.9, relevance: 0.1)]
    let passed = RecallGate.select(results, query: "billing invoices question", config: cfg)
    #expect(passed.count == 1)
}
