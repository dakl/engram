import Foundation
import Testing
@testable import EngramCore

private func makeTempStore() throws -> (MemoryStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-test-\(UUID().uuidString).sqlite")
    return (try MemoryStore(url: url), url)
}

@Test func storeThenFetchReturnsSemanticMatch() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try await store.store(content: "The deployment pipeline runs on Kubernetes via ArgoCD.", tags: ["infra"])
    try await store.store(content: "My favourite pizza topping is mushrooms.", tags: ["food"])

    let results = try await store.fetch(query: "how do we deploy services to the cluster?", limit: 1)
    #expect(results.count == 1)
    #expect(results.first?.memory.content.contains("Kubernetes") == true)
}

@Test func hybridSearchFindsExactTermSemanticAloneMissed() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try await store.store(content: "soundtrack-graph is Soundtrack's GraphQL aggregation layer over upstream services.",
                          tags: ["service", "soundtrack-graph"])
    try await store.store(content: "The billing service issues invoices and refunds.", tags: ["service", "billing"])
    try await store.store(content: "Daniel prefers uv over pip for Python.", tags: ["python"])

    let results = try await store.fetch(query: "what does soundtrack graph do?", limit: 1)
    #expect(results.first?.memory.content.contains("soundtrack-graph") == true)
    // It should win via the lexical (keyword) leg of the hybrid search.
    #expect(results.first?.lexicalMatch == true)
}

@Test func ftsKeepsSingleCharIdentifiersButDropsStopwords() {
    // P2 #9: a one-char identifier/symbol query keeps a lexical leg…
    #expect(MemoryStore.ftsMatchExpression(for: "x") != nil)
    #expect(MemoryStore.ftsMatchExpression(for: "C") != nil)
    // …while single-char stopwords and empty queries still yield no lexical query.
    #expect(MemoryStore.ftsMatchExpression(for: "a") == nil)
    #expect(MemoryStore.ftsMatchExpression(for: "the") == nil)
}

@Test func fetchMarksMemoriesAccessed() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let stored = try await store.store(content: "Engram stores memories locally.")
    _ = try await store.fetch(query: "where are memories stored", limit: 1)

    let reloaded = await store.fetch(id: stored.id)
    #expect(reloaded?.accessCount == 1)
    #expect(reloaded?.lastAccessedAt != nil)
}

@Test func softDeleteHidesFromFetchButKeepsTombstone() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let stored = try await store.store(content: "Temporary note about the staging environment.")
    try await store.delete(id: stored.id)

    let results = try await store.fetch(query: "staging environment note", limit: 5)
    #expect(results.allSatisfy { $0.memory.id != stored.id })

    let tombstone = await store.fetch(id: stored.id)
    #expect(tombstone?.deletedAt != nil)
}

@Test func updateRevisesContentAndIsSearchableUnderNewMeaning() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let stored = try await store.store(content: "The billing service handles invoices.", tags: ["service"])
    let updated = try await store.update(
        id: stored.id,
        content: "The billing service handles invoices, refunds, and tax reporting in Go.",
        tags: ["service", "billing"]
    )

    #expect(updated?.content.contains("refunds") == true)
    #expect(updated?.tags.contains("billing") == true)
    #expect((updated?.updatedAt ?? .distantPast) >= stored.updatedAt)

    // Re-embedded content should match a query about the new meaning.
    let results = try await store.fetch(query: "which service does tax reporting?", limit: 1)
    #expect(results.first?.memory.id == stored.id)
}

@Test func updateUnknownIdReturnsNil() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await store.update(id: UUID(), content: "nope") == nil)
}

@Test func updateSetsVerifiabilityAndCheckAnchor() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    // Stored without an anchor; default verifiability is userConfirmOnly.
    let stored = try await store.store(content: "voice-service does TTS.", tags: ["service"])
    #expect(stored.checkAnchor == nil)

    let updated = try await store.update(
        id: stored.id,
        verifiability: .codeGrounded,
        checkAnchor: "internal/tts/synth.go"
    )
    #expect(updated?.verifiability == .codeGrounded)
    #expect(updated?.checkAnchor == "internal/tts/synth.go")

    // Omitting them on a later update must not clear the persisted values.
    let renamed = try await store.update(id: stored.id, content: "voice-service does text-to-speech.")
    #expect(renamed?.checkAnchor == "internal/tts/synth.go")
    #expect(renamed?.verifiability == .codeGrounded)
}

@Test func verificationFieldsRoundTrip() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let stored = try await store.store(
        content: "The billing service is written in Go.",
        tags: ["service", "billing"],
        verifiability: .codeGrounded,
        checkAnchor: "billing/main.go"
    )

    let reloaded = await store.fetch(id: stored.id)
    #expect(reloaded?.verifiability == .codeGrounded)
    #expect(reloaded?.checkAnchor == "billing/main.go")
    #expect(reloaded?.confidence == 1.0)
    #expect(reloaded?.verifiedAt == nil)
    #expect(reloaded?.supersededBy == nil)
}

@Test func titleRoundTripsAndFallsBackToFirstLine() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    // Authored title persists and is what displayTitle shows.
    let titled = try await store.store(
        title: "Engram uses NLContextualEmbedding",
        content: "# embeddings\n\nAs of ADR 0012, Engram embeds on-device."
    )
    let reloadedTitled = await store.fetch(id: titled.id)
    #expect(reloadedTitled?.title == "Engram uses NLContextualEmbedding")
    #expect(reloadedTitled?.displayTitle == "Engram uses NLContextualEmbedding")

    // No title → displayTitle falls back to the first content line, sans `#`.
    let untitled = try await store.store(content: "# studio-api — purpose\n\nA service.")
    let reloadedUntitled = await store.fetch(id: untitled.id)
    #expect(reloadedUntitled?.title == nil)
    #expect(reloadedUntitled?.displayTitle == "studio-api — purpose")

    // Title is editable independently of content.
    let retitled = try await store.update(id: untitled.id, title: "Studio API service")
    #expect(retitled?.title == "Studio API service")
    #expect(retitled?.content.contains("studio-api — purpose") == true)
}

@Test func migrationIsIdempotentAcrossStoreInstances() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-test-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let first = try MemoryStore(url: url)
    let stored = try await first.store(
        content: "Daniel prefers uv over pip.",
        tags: ["python"],
        verifiability: .userConfirmOnly
    )

    // Re-opening runs migrate() again; it must be a no-op and the row intact.
    let second = try MemoryStore(url: url)
    let reloaded = await second.fetch(id: stored.id)
    #expect(reloaded?.content == "Daniel prefers uv over pip.")
    #expect(reloaded?.verifiability == .userConfirmOnly)
    #expect(reloaded?.confidence == 1.0)
}

@Test func markVerifiedSetsVerifiedAtAndConfidence() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let stored = try await store.store(content: "The billing service is written in Go.", tags: ["service"])
    #expect(stored.verifiedAt == nil)

    let verified = try await store.markVerified(id: stored.id, confidence: 0.8)
    #expect(verified?.verifiedAt != nil)
    #expect(verified?.confidence == 0.8)

    let reloaded = await store.fetch(id: stored.id)
    #expect(reloaded?.verifiedAt != nil)
    #expect(reloaded?.confidence == 0.8)
}

@Test func markVerifiedUnknownIdReturnsNil() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await store.markVerified(id: UUID(), confidence: nil) == nil)
}

@Test func supersedeLinksOldAndDropsItFromActive() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let old = try await store.store(
        content: "The billing service runs on Python.",
        tags: ["service", "billing"]
    )
    // Confirm the old memory is findable before superseding.
    let before = try await store.fetch(query: "what language is the billing service?", limit: 5)
    #expect(before.contains { $0.memory.id == old.id })

    let new = try await store.supersede(
        id: old.id,
        content: "The billing service runs on Go.",
        reason: "rewritten in Go",
        tags: ["service", "billing"],
        source: nil,
        verifiability: .codeGrounded
    )
    let newID = try #require(new?.id)

    // Old memory: linked, history preserved, but no longer active.
    let oldReloaded = await store.fetch(id: old.id)
    #expect(oldReloaded?.supersededBy == newID)
    #expect(oldReloaded?.evolutionReason == "rewritten in Go")

    let listed = try await store.list()
    #expect(listed.contains { $0.id == newID })
    #expect(!listed.contains { $0.id == old.id })

    let after = try await store.fetch(query: "what language is the billing service?", limit: 5)
    #expect(!after.contains { $0.memory.id == old.id })
    #expect(after.contains { $0.memory.id == newID })

    let stats = try await store.stats()
    #expect(stats.totalActive == 1)
}

@Test func supersedeUnknownIdReturnsNil() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try await store.supersede(
        id: UUID(), content: "x", reason: "y", tags: [], source: nil, verifiability: .userConfirmOnly
    )
    #expect(result == nil)
}

@Test func exportAllReturnsActiveSupersededAndTombstonedHistory() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    // Active memory.
    let active = try await store.store(content: "An active memory.")
    // A memory that gets superseded (the old row becomes history).
    let old = try await store.store(content: "The billing service runs on Python.", tags: ["service"])
    let new = try #require(try await store.supersede(
        id: old.id, content: "The billing service runs on Go.",
        reason: "rewritten in Go", tags: ["service"], source: nil, verifiability: .codeGrounded
    ))
    // A soft-deleted (tombstoned) memory.
    let deleted = try await store.store(content: "A note to be deleted.")
    try await store.delete(id: deleted.id)

    let exported = try await store.exportAll()
    let exportedIDs = Set(exported.map(\.id))

    // All four rows are present: active, the superseding new one, the superseded
    // old one, and the tombstoned one — none are filtered out.
    #expect(exportedIDs.contains(active.id))
    #expect(exportedIDs.contains(new.id))
    #expect(exportedIDs.contains(old.id))
    #expect(exportedIDs.contains(deleted.id))

    // History markers survive the round-trip.
    #expect(exported.first { $0.id == old.id }?.supersededBy == new.id)
    #expect(exported.first { $0.id == deleted.id }?.deletedAt != nil)

    // Newest first.
    #expect(exported == exported.sorted { $0.createdAt > $1.createdAt })
}

@Test func statsReflectStoredMemories() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try await store.store(content: "First memory.", tags: ["alpha"])
    try await store.store(content: "Second memory.", tags: ["alpha", "beta"])
    _ = try await store.fetch(query: "memory", limit: 2)

    let stats = try await store.stats()
    #expect(stats.totalActive == 2)
    #expect(stats.createdLast7Days == 2)
    #expect(stats.totalAccesses >= 1)
    #expect(stats.topTags.first?.tag == "alpha")
}

// MARK: - Retrieval activity (ADR 0015)

@Test func recordRetrievalIsQueryableWithinWindowAndFiltersBySource() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let recalled = try await store.store(content: "Recalled via the prompt hook.")
    let digested = try await store.store(content: "Listed by the session digest.")
    try await store.recordRetrieval(memoryIDs: [recalled.id], source: .recall, query: "the prompt")
    try await store.recordRetrieval(memoryIDs: [digested.id], source: .sessionDigest)

    let recent = try await store.retrievals(since: Date().addingTimeInterval(-3600))
    #expect(recent.count == 2)
    #expect(recent.contains { $0.memoryID == recalled.id && $0.source == .recall && $0.query == "the prompt" })
    #expect(recent.contains { $0.memoryID == digested.id && $0.source == .sessionDigest && $0.query == nil })

    // Source filter narrows to one mode.
    let onlyRecall = try await store.retrievals(since: Date().addingTimeInterval(-3600), source: .recall)
    #expect(onlyRecall.map(\.memoryID) == [recalled.id])

    // A window that starts in the future excludes rows recorded now.
    let future = try await store.retrievals(since: Date().addingTimeInterval(3600))
    #expect(future.isEmpty)
}

@Test func activityMergesReadsAndWritesNewestFirstExcludingAccessed() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    // A write (store records `.created`), then a read on it, then an edit.
    let stored = try await store.store(content: "A memory that gets touched.")
    try await store.recordRetrieval(memoryIDs: [stored.id], source: .recall, query: "touch it")
    _ = try await store.update(id: stored.id, content: "An edited memory.")
    // A deliberate search bumps `access_count` and logs an `accessed` lifecycle
    // event — which the unified timeline must NOT surface (ADR 0020).
    _ = try await store.fetch(query: "edited memory", limit: 1)

    let activity = try await store.activity(since: Date().addingTimeInterval(-3600))
    let kinds = activity.map(\.kind)

    // Reads and writes both appear; `accessed` is excluded.
    #expect(kinds.contains(.store))
    #expect(kinds.contains(.update))
    #expect(kinds.contains(.recall))
    // `accessed` is excluded: the search's accessed event never becomes an
    // activity kind, so the only read in the feed is the explicit recall.
    #expect(kinds.filter { !$0.isWrite }.allSatisfy { $0 == .recall })
    // The read carried its query; writes carry none.
    #expect(activity.contains { $0.kind == .recall && $0.query == "touch it" })
    #expect(activity.allSatisfy { !$0.kind.isWrite || $0.query == nil })
    // Newest first, and ids are unique across the two ledgers.
    #expect(activity == activity.sorted { $0.at > $1.at })
    #expect(Set(activity.map(\.id)).count == activity.count)
}

@Test func recordRetrievalDoesNotBumpAccessCount() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let stored = try await store.store(content: "Surfacing must not inflate ranking (ADR 0005).")
    try await store.recordRetrieval(memoryIDs: [stored.id], source: .recall, query: "anything")

    let reloaded = await store.fetch(id: stored.id)
    #expect(reloaded?.accessCount == 0)
    #expect(reloaded?.lastAccessedAt == nil)
}

@Test func lookbackParsesUnitsAndRejectsGarbage() {
    #expect(Lookback.parse("15m") == 900)
    #expect(Lookback.parse("1h") == 3600)
    #expect(Lookback.parse("6h") == 21600)
    #expect(Lookback.parse("1d") == 86400)
    #expect(Lookback.parse("90m") == 5400)
    #expect(Lookback.parse("0h") == nil)
    #expect(Lookback.parse("h") == nil)
    #expect(Lookback.parse("1w") == nil)
    #expect(Lookback.parse("abc") == nil)
}
