import Testing
import EngramCore
@testable import Engram

struct EngramTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    /// Regression test for issue #2: clicking a non-first activity row for a memory that
    /// appears in multiple rows (e.g., recalled twice) jumps the selection to the first
    /// (topmost) row for that memory instead of staying on the clicked row.
    ///
    /// Root cause: `ActivityView.selection.get` uses
    /// `activityRows.first { $0.memory?.id == selected.id }` which always picks the
    /// first match (newest event = top of Table), ignoring which specific event was clicked.
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

        // Simulate clicking rowB: selection.set(rowB.id) fires and sets selectedMemory = memory.
        let selectedMemory: Memory? = memory

        // Replicate the selection.get closure from ActivityView verbatim.
        // After clicking rowB this should return rowB.id so the Table highlights rowB.
        let resolved = selectedMemory.flatMap { selected in
            activityRows.first { $0.memory?.id == selected.id }?.id
        }

        // BUG: resolved == "r:1" (rowA.id, the top row), not "r:2" (rowB.id).
        // The Table selection jumps to the topmost event for the memory on every click.
        #expect(resolved == rowB.id)
    }
}
