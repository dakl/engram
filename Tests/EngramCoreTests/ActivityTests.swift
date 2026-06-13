import Foundation
import Testing
@testable import EngramCore

private func makeTempStore() throws -> (MemoryStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-activity-test-\(UUID().uuidString).sqlite")
    return (try MemoryStore(url: url), url)
}

/// Multiple recall events for the same memory — the scenario that triggered issue #2.
/// The activity feed must list all of them, newest first, each with its own query.
@Test func multipleRecallsForSameMemoryAllAppearInActivity() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let memory = try await store.store(content: "Deployed via ArgoCD on Kubernetes.", tags: ["infra"])
    try await store.recordRetrieval(memoryIDs: [memory.id], source: .recall, query: "first question")
    try await store.recordRetrieval(memoryIDs: [memory.id], source: .recall, query: "second question")

    let activity = try await store.activity(since: Date().addingTimeInterval(-60))
    let recalls = activity.filter { $0.memoryID == memory.id && $0.kind == .recall }

    #expect(recalls.count == 2)
    #expect(recalls[0].at >= recalls[1].at, "activity must be newest-first")
    #expect(Set(recalls.compactMap(\.query)) == ["first question", "second question"])
}

/// Activity events from the two ledgers (retrievals + lifecycle) must have distinct IDs
/// even when they touch the same memory, so the Table's `Identifiable` rows never collide.
@Test func activityEventIDsAreUniqueAcrossLedgers() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let m = try await store.store(content: "A touched memory.", tags: [])
    try await store.recordRetrieval(memoryIDs: [m.id], source: .recall, query: "q")
    _ = try await store.update(id: m.id, content: "Updated content.")

    let activity = try await store.activity(since: Date().addingTimeInterval(-60))
    let ids = activity.map(\.id)
    #expect(Set(ids).count == ids.count, "each ActivityEvent must have a unique id")
    #expect(ids.contains { $0.hasPrefix("r:") }, "recall events get 'r:' prefix")
    #expect(ids.contains { $0.hasPrefix("e:") }, "lifecycle events get 'e:' prefix")
}

/// The lookback window (`since:`) is enforced: a window starting in the future
/// returns nothing, while a generous window captures all recent events.
@Test func activityRespectsLookbackWindow() async throws {
    let (store, url) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let m = try await store.store(content: "Old memory.", tags: [])
    try await store.recordRetrieval(memoryIDs: [m.id], source: .recall, query: "q")

    let future = try await store.activity(since: Date().addingTimeInterval(60))
    #expect(future.isEmpty, "a window starting in the future should be empty")

    let recent = try await store.activity(since: Date().addingTimeInterval(-60))
    #expect(!recent.isEmpty)
}
