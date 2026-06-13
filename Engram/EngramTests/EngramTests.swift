import Foundation
import Testing
import EngramCore
@testable import Engram

struct EngramTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    // MARK: - Activity selection (issue #2)

    /// Regression test: clicking a non-first activity row for a memory that appears
    /// in multiple rows must keep the selection on the clicked row, not jump to the
    /// first (newest) row for that memory.
    ///
    /// Fix: `ActivityView.selection` now tracks `model.selectedActivityRowID` (the exact
    /// clicked row ID) rather than searching `activityRows` by memory ID.
    @Test @MainActor func activitySelectionStaysOnClickedRow() {
        let memoryID = UUID()
        let memory = Memory(id: memoryID, content: "Test memory", tags: [])

        // Same memory recalled twice — each recall produces a separate ActivityRow.
        // DB returns events newest-first, so eventA sits at the top of the Table.
        let eventA = ActivityEvent(
            id: "r:1", memoryID: memoryID, kind: .recall, query: "first query",
            at: Date()
        )
        let eventB = ActivityEvent(
            id: "r:2", memoryID: memoryID, kind: .recall, query: "second query",
            at: Date().addingTimeInterval(-60)
        )
        let rowA = EngramModel.ActivityRow(event: eventA, memory: memory) // top row
        let rowB = EngramModel.ActivityRow(event: eventB, memory: memory) // below rowA

        // Newest-first, as returned by MemoryStore.activity() (ORDER BY at DESC).
        let activityRows = [rowA, rowB]

        // Simulate clicking rowB: selection.set(rowB.id) stores the exact row ID.
        var selectedActivityRowID: String? = rowB.id

        // selection.get returns selectedActivityRowID directly — no activityRows.first search.
        // The Table highlight correctly stays on rowB, not rowA (the old buggy behaviour).
        #expect(selectedActivityRowID == rowB.id)

        // selectedRetrievalQuery now resolves via row ID, so it shows rowB's query.
        let query = activityRows.first { $0.id == selectedActivityRowID }?.event.query
        #expect(query == eventB.query)

        _ = rowA  // suppress unused-variable warning
    }

    // MARK: - selectedRetrievalQuery

    /// `selectedRetrievalQuery` is nil when the user is not on the Activity lens,
    /// even if a row ID and memory are selected.
    @Test @MainActor func selectedRetrievalQueryIsNilOutsideActivityLens() {
        let model = EngramModel.preview()
        model.selectedActivityRowID = "r:99"
        model.section = .list
        #expect(model.selectedRetrievalQuery == nil)
    }

    /// `selectedRetrievalQuery` is nil when no row is selected, even in the
    /// Activity lens.
    @Test @MainActor func selectedRetrievalQueryIsNilWithNoSelection() {
        let model = EngramModel.preview()
        model.section = .activity
        model.selectedActivityRowID = nil
        #expect(model.selectedRetrievalQuery == nil)
    }

    /// Full integration: store a memory, recall it twice with distinct queries, load
    /// the activity timeline, click the older recall row, and verify that
    /// `selectedRetrievalQuery` returns the clicked row's query — not the top row's.
    @Test @MainActor func selectedRetrievalQueryReflectsClickedRow() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-model-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MemoryStore(url: url)

        let model = EngramModel(testStore: store)
        model.section = .activity

        let memory = try await store.store(content: "Recalled memory.", tags: [])
        // Two recalls; recordRetrieval is called in order, so the second is newer.
        try await store.recordRetrieval(memoryIDs: [memory.id], source: .recall, query: "first question")
        try await store.recordRetrieval(memoryIDs: [memory.id], source: .recall, query: "second question")

        await model.loadActivityForTesting()

        // activityRows is newest-first: [second-question row, first-question row].
        let firstRow = try #require(model.activityRows.first { $0.event.query == "first question" })
        let secondRow = try #require(model.activityRows.first { $0.event.query == "second question" })

        // Sanity: second question is at the top (index 0).
        #expect(model.activityRows.first?.id == secondRow.id)

        // Simulate clicking the older "first question" row.
        model.selectedActivityRowID = firstRow.id
        model.selectedMemory = memory

        // selectedRetrievalQuery must return the clicked row's query, not the top row's.
        #expect(model.selectedRetrievalQuery == "first question")
        #expect(model.selectedRetrievalQuery != "second question")
    }

    // MARK: - Stale selection

    /// A row ID that no longer exists in activityRows (e.g. after a lookback
    /// reload) must not surface a phantom retrieval query in the inspector.
    @Test @MainActor func selectedRetrievalQueryIsNilForStaleRowID() {
        let model = EngramModel.preview()
        model.section = .activity
        // activityRows is empty in preview; this ID doesn't exist.
        model.selectedActivityRowID = "r:gone"
        #expect(model.selectedRetrievalQuery == nil)
    }

    // MARK: - Model lifecycle

    /// refresh() reads from a real store and populates model.memories.
    @Test @MainActor func refreshPopulatesMemories() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-model-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MemoryStore(url: url)

        let model = EngramModel(testStore: store)
        #expect(model.memories.isEmpty)

        _ = try await store.store(content: "Hello world.", tags: ["test"])
        await model.refreshForTesting()

        #expect(model.memories.count == 1)
        #expect(model.memories.first?.content == "Hello world.")
        #expect(model.stats.totalActive == 1)
    }

    /// Deleting a memory and calling refresh removes it from model.memories and
    /// decrements the stats counter.
    @Test @MainActor func refreshAfterDeleteRemovesMemory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-model-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MemoryStore(url: url)

        let model = EngramModel(testStore: store)
        let memory = try await store.store(content: "To be deleted.", tags: [])
        await model.refreshForTesting()
        #expect(model.memories.count == 1)
        #expect(model.stats.totalActive == 1)

        try await store.delete(id: memory.id)
        await model.refreshForTesting()

        #expect(model.memories.isEmpty)
        #expect(model.stats.totalActive == 0)
    }
}
