import SwiftUI
import EngramCore

/// The List lens's detail content (ADR 0013/0014/0016): a native `List` that
/// shows a Top Hit + results while searching, a filtered list when facets are
/// selected (in the sidebar), and otherwise the home shelves. Rows are the
/// canonical `MemoryRow`; selecting one opens it in the inspector.
struct ListDetail: View {
    let model: EngramModel

    /// The memory the context-menu Delete is asking to confirm (P1 #12). Routes
    /// every list delete through the same `confirmationDialog` the inspector uses.
    @State private var pendingDelete: Memory?

    var body: some View {
        Group {
            if model.memories.isEmpty {
                ContentUnavailableView {
                    Label("No memories yet", systemImage: "tray")
                } description: {
                    Text("Store some via the engram CLI, or your Claude Code hooks.")
                } actions: {
                    Button("Connect Claude Code") { model.pendingInstall = .integration }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if model.isSearching {
                        searchSections
                    } else if model.hasFacetFilter {
                        filteredSection
                    } else {
                        shelfSections
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { memory in
            Button("Delete", role: .destructive) {
                model.delete(memory.id)
                if model.selectedMemory?.id == memory.id { model.selectedMemory = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var searchSections: some View {
        if model.searchResults.isEmpty {
            Section {
                Text("No matching memories").foregroundStyle(.secondary)
            }
        } else {
            if let top = model.searchResults.first {
                Section("Top Hit") { memoryRow(top.memory, score: top.score) }
            }
            if model.searchResults.count > 1 {
                Section("More results") {
                    ForEach(model.searchResults.dropFirst()) { result in
                        memoryRow(result.memory, score: result.score)
                    }
                }
            }
        }
    }

    private var filteredSection: some View {
        let results = model.filteredMemories
        return Section("\(results.count) matching") {
            if results.isEmpty {
                Text("No memories match these facets").foregroundStyle(.secondary)
            } else {
                ForEach(results) { memoryRow($0, score: nil) }
            }
        }
    }

    @ViewBuilder
    private var shelfSections: some View {
        shelf("Recents", model.recentMemories)
        if !model.mostUsedMemories.isEmpty { shelf("Most used", model.mostUsedMemories) }
        if !model.staleMemories.isEmpty { shelf("Stale — verify", model.staleMemories) }
        if !model.untaggedMemories.isEmpty { shelf("Untagged", model.untaggedMemories) }
    }

    private func shelf(_ title: String, _ memories: [Memory]) -> some View {
        Section(title) {
            ForEach(memories) { memoryRow($0, score: nil) }
        }
    }

    // MARK: - Row

    private func memoryRow(_ memory: Memory, score: Double?) -> some View {
        Button { model.selectedMemory = memory } label: {
            MemoryRow(
                memory: memory,
                score: score,
                onTapTag: { model.focusTag($0) },
                onTapSource: { model.focusTag($0) }
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(
            model.selectedMemory?.id == memory.id ? Color.accentColor.opacity(0.12) : Color.clear
        )
        .contextMenu {
            Button("Edit", systemImage: "pencil") { model.selectedMemory = memory }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = memory }
        }
    }
}
