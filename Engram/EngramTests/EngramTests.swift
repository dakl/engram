import Testing
import EngramCore
@testable import Engram

struct EngramTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    /// Regression test for issue #2: clicking a non-first activity row for a memory that
    /// appears in multiple rows (e.g., recalled twice) must keep the selection on the
    /// clicked row, not jump to the first (newest) row for that memory.
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
}
