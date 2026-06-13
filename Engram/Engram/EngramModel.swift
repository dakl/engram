import Foundation
import Observation
import EngramCore

/// Main-actor view model backing the app. Owns a single `MemoryStore`
/// (the same database the `engram` CLI writes to) and publishes the stats
/// and memory list the UI renders.
@Observable
@MainActor
final class EngramModel {
    private(set) var stats = MemoryStats()
    private(set) var memories: [Memory] = []
    private(set) var searchResults: [ScoredMemory] = []
    private(set) var errorMessage: String?
    var searchQuery = ""

    /// The memory currently shown in the trailing inspector (ADR 0016). Selecting
    /// a row/node in any lens sets this; the inspector edits it in place.
    var selectedMemory: Memory?

    /// The app's lenses, shown as sidebar rows (ADR 0019): the **Tags** faceted
    /// list (replacing the old Structure icicle) and the **Map** (now a bipartite
    /// tag-graph). All four ship — no beta gating.
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case list, tags, map, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .list: return "List"
            case .tags: return "Tags"
            case .map: return "Map"
            case .activity: return "Activity"
            }
        }
        var systemImage: String {
            switch self {
            case .list: return "list.bullet"
            case .tags: return "tag"
            case .map: return "circle.grid.2x2"
            case .activity: return "clock.arrow.circlepath"
            }
        }
        /// All lenses are always visible (ADR 0018 removed the gated graph lens).
        static var visibleCases: [Section] { allCases }
    }
    var section: Section = .list

    // MARK: - Tags lens state (ADR 0019)

    /// A tag to focus in the Tags lens: a reserved facet key (or `nil` for a
    /// freeform tag) plus the value. Clicking a chip/source on any memory row sets
    /// this and switches to the Tags lens, which scrolls to and expands the tag.
    struct TagFocus: Hashable {
        /// The reserved facet this tag belongs to, or `nil` for a freeform `#tag`.
        let facet: FacetKey?
        let value: String
    }

    /// The tag the Tags lens should reveal (scroll-to + expand), if any. Cleared
    /// once consumed by the view so a later identical tap re-fires.
    var focusedTag: TagFocus?

    /// Focuses a tag and switches to the Tags lens — the navigation target for
    /// tappable chips/source in `MemoryRow` and the Map's tag hubs (ADR 0019).
    func focusTag(_ focus: TagFocus) {
        focusedTag = focus
        section = .tags
    }

    /// Selected facet filters for the List lens (ADR 0013), lifted here so the
    /// sidebar (which toggles them) and the detail list (which applies them)
    /// share one source of truth.
    var selectedFacets: Set<FacetSelection> = []

    /// A chosen facet value, e.g. `type:decision`.
    struct FacetSelection: Hashable {
        let key: FacetKey
        let value: String
    }

    /// A unified activity row: a read or write event joined to its memory (nil if
    /// the memory is gone), for the Activity timeline (ADR 0015/0020).
    struct ActivityRow: Identifiable {
        let event: ActivityEvent
        let memory: Memory?
        var id: String { event.id }
    }

    /// Lookback window for the Activity view; changing it reloads the timeline.
    var activityLookback: Lookback = .h1
    private(set) var activityRows: [ActivityRow] = []

    /// The specific activity row the user last clicked, tracked separately from
    /// `selectedMemory` so the Table highlight stays on the exact clicked event
    /// rather than always snapping to the first (newest) event for that memory.
    var selectedActivityRowID: String?

    /// The full prompt that retrieved the selected memory, surfaced above it in
    /// the inspector (the Activity table truncates the Query column). Only set in
    /// the Activity lens, so it self-clears when switching lenses or selecting a
    /// memory elsewhere.
    var selectedRetrievalQuery: String? {
        guard section == .activity, let rowID = selectedActivityRowID else { return nil }
        let query = activityRows.first { $0.id == rowID }?.event.query
        return query?.isEmpty == true ? nil : query
    }

    private let store: MemoryStore?
    private var searchTask: Task<Void, Never>?

    /// Whether a real on-disk store opened. False in previews/sample data, so the
    /// first-run onboarding only fires for the live app.
    var storeAvailable: Bool { store != nil }

    /// True when recall is running on the degraded fallback embedder rather than
    /// the on-device contextual model (ADR 0012). Surfaced subtly in the sidebar
    /// so the user knows search quality is reduced. Captured on `refresh()`.
    private(set) var usingFallbackEmbedder = false

    /// True while a manual re-index is rebuilding the embedder + re-embedding —
    /// drives the spinner and disables the "Re-index" affordances.
    private(set) var isReindexing = false

    /// Polls the shared store file so external writes (CLI, Claude Code hooks,
    /// other processes) refresh the UI. Only created when a real store opened —
    /// never in `preview()`/sample init.
    private var storeWatcher: StoreWatcher?

    init() {
        do {
            self.store = try MemoryStore()
        } catch {
            self.store = nil
            self.errorMessage = "Couldn't open the memory store: \(error)"
        }
        refresh()

        // Watch the store on disk so changes made by other processes show up
        // automatically. The watcher fires on a background queue, so hop to the
        // main actor and refresh. `refresh()` only READS (stats/list/graph), so
        // a watcher-triggered refresh never writes back to the store and so
        // can't re-trigger the watcher — no feedback loop. Weak self keeps the
        // watcher from retaining the model.
        if store != nil {
            self.storeWatcher = StoreWatcher(fileURL: EngramPaths.defaultDatabaseURL) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// Builds a model backed by in-memory sample data and no `MemoryStore`,
    /// so SwiftUI previews never open the real database.
    private init(sampleStats: MemoryStats, sampleMemories: [Memory]) {
        self.store = nil
        self.stats = sampleStats
        self.memories = sampleMemories
    }

    static func preview() -> EngramModel {
        EngramModel(
            sampleStats: MemoryStats(
                totalActive: 431,
                totalDeleted: 3,
                createdLast7Days: 12,
                accessedLast7Days: 54,
                totalAccesses: 1287,
                databaseBytes: 68_100_000,
                topTags: [("infra", 42), ("python", 17), ("prefs", 8), ("engram", 5)]
            ),
            sampleMemories: [
                Memory(content: "The prod GCP project is es-platform-prod.",
                       tags: ["infra", "gcp"], source: "notes", accessCount: 9),
                Memory(content: "Daniel prefers uv over pip for Python package management.",
                       tags: ["python", "prefs"], accessCount: 4),
                Memory(content: "Engram embeds memories on-device via NLEmbedding (512-dim).",
                       tags: ["engram", "design"], accessCount: 2),
            ]
        )
    }

    /// Reloads stats and the recent-memories list. The store work runs on the
    /// `MemoryStore` actor (off the main actor); results publish back on main.
    func refresh() {
        guard let store else { return }
        Task {
            do {
                let stats = try await store.stats()
                let memories = try await store.list(limit: 200)
                let fallback = await store.isUsingFallbackEmbedder
                self.stats = stats
                self.memories = memories
                self.usingFallbackEmbedder = fallback
                // NB: we deliberately do NOT build the semantic graph/communities
                // here. `store.graph()` re-embeds every memory, and this runs on
                // every 1s StoreWatcher tick — a real perf/battery cliff — yet
                // nothing consumed `graph`/`clusters` after the tag-centric redesign
                // (ADR 0019). The Map builds its own tag graph from `memories`.
                if self.section == .activity { self.loadActivity() }
            } catch {
                self.errorMessage = "\(error)"
            }
        }
    }

    /// Manually rebuilds the embedder and re-embeds all memories — the in-session
    /// recovery when recall has degraded to the fallback model (ADR 0012). Safe to
    /// invoke anytime (a no-op when nothing changed). Serializes on the store actor;
    /// `isReindexing` drives the UI spinner.
    func reindex() {
        guard let store, !isReindexing else { return }
        isReindexing = true
        Task {
            do {
                _ = try await store.reindex()
                self.usingFallbackEmbedder = await store.isUsingFallbackEmbedder
                self.refresh()
            } catch {
                self.errorMessage = "\(error)"
            }
            self.isReindexing = false
        }
    }

    /// Loads the unified activity timeline (reads + writes) for the current lookback
    /// window (ADR 0015/0020), resolving each event's memory (tombstoned ones still
    /// resolve, shown dimmed; truly missing ones render as deleted). Read-only.
    func loadActivity() {
        guard let store else { return }
        let since = Date().addingTimeInterval(-activityLookback.interval)
        Task {
            do {
                let events = try await store.activity(since: since)
                var resolved: [UUID: Memory?] = [:]
                var rows: [ActivityRow] = []
                for event in events {
                    if resolved[event.memoryID] == nil {
                        resolved[event.memoryID] = await store.fetch(id: event.memoryID)
                    }
                    rows.append(ActivityRow(event: event, memory: resolved[event.memoryID] ?? nil))
                }
                self.activityRows = rows
            } catch {
                self.errorMessage = "\(error)"
            }
        }
    }

    /// Runs a debounced semantic search (~250 ms) off the main actor. Empty query
    /// clears results back to the browse list. Typing cancels the in-flight task,
    /// so a full embed+query no longer runs on every keystroke.
    func search() {
        searchTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            do {
                // Read-only: browsing/searching in the app shouldn't bump
                // access counts or touch the store file (which would trip the
                // watcher). Deliberate writes go through saveEdit/delete.
                let results = try await store.fetch(query: trimmed, limit: 25, recordAccess: false)
                if Task.isCancelled { return }
                self.searchResults = results
            } catch {
                self.errorMessage = "\(error)"
            }
        }
    }

    /// Clears the current error so the alert can be dismissed.
    func dismissError() {
        errorMessage = nil
    }

    /// Ids of the current search hits — for the Map's search-to-highlight (ADR 0018).
    var searchResultIDs: Set<UUID> { Set(searchResults.map { $0.memory.id }) }

    /// Nearest semantic neighbours of a memory, for the Map's find-similar rays
    /// (ADR 0018). Read-only; resolves off the main actor.
    func neighbors(of id: UUID, limit: Int = 6) async -> [UUID] {
        guard let store else { return [] }
        return (try? await store.neighbors(of: id, limit: limit)) ?? []
    }

    /// Persists edited content/tags/source off the main actor, then refreshes so
    /// both the list and graph reflect the change. Mirrors `delete(_:)`.
    func saveEdit(id: UUID, title: String?, content: String, tags: [String], source: String?) {
        guard let store else { return }
        Task {
            do {
                // `Optional(title)` always sets the field (an empty title clears it,
                // falling back to the content's first line — ADR 0014).
                _ = try await store.update(id: id, title: Optional(title), content: content, tags: tags, source: source)
                self.refresh()
            } catch {
                self.errorMessage = "\(error)"
            }
        }
    }

    func delete(_ id: UUID) {
        guard let store else { return }
        Task {
            do {
                try await store.delete(id: id)
                self.searchResults.removeAll { $0.memory.id == id }
                self.refresh()
            } catch {
                self.errorMessage = "\(error)"
            }
        }
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var formattedDatabaseSize: String {
        ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file)
    }

    // MARK: - Facets & shelves (ADR 0013/0016)

    /// Distinct values + counts for a facet key across active memories, busiest
    /// first — drives the sidebar facet sections.
    func facetCounts(for key: FacetKey) -> [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for memory in memories {
            for value in memory.facets.values(key) { counts[value, default: 0] += 1 }
        }
        return counts.map { (value: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    // MARK: - Tag index (ADR 0019 — Tags lens)

    /// One tag and the memories carrying it, for the Tags lens. A facet tag
    /// (`type:decision`) is keyed by its value ("decision") under its facet's
    /// section; a freeform tag (`infra`) lives under the freeform section with a
    /// `nil` facet.
    struct TagBucket: Identifiable {
        let facet: FacetKey?
        let value: String
        let memories: [Memory]
        /// Stable across redraws: facet key (or "tag") + value.
        var id: String { "\(facet?.rawValue ?? "tag"):\(value)" }
        var count: Int { memories.count }
        var focus: TagFocus { TagFocus(facet: facet, value: value) }
    }

    /// All tag buckets for one facet section across active memories. Pass `nil` for
    /// the freeform `#tag` section. Sorted by member count desc, then value alpha —
    /// deterministic. Each memory contributes once per distinct value it carries.
    func tagBuckets(for facet: FacetKey?) -> [TagBucket] {
        var membersByValue: [String: [Memory]] = [:]
        for memory in memories {
            let values: [String]
            if let facet {
                values = memory.facets.values(facet)
            } else {
                values = memory.facets.freeform
            }
            for value in Set(values) {
                membersByValue[value, default: []].append(memory)
            }
        }
        return membersByValue
            .map { TagBucket(facet: facet, value: $0.key, memories: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    func isFacetSelected(_ key: FacetKey, _ value: String) -> Bool {
        selectedFacets.contains(FacetSelection(key: key, value: value))
    }

    func toggleFacet(_ key: FacetKey, _ value: String) {
        let facet = FacetSelection(key: key, value: value)
        if selectedFacets.contains(facet) { selectedFacets.remove(facet) } else { selectedFacets.insert(facet) }
    }

    var hasFacetFilter: Bool { !selectedFacets.isEmpty }

    /// Memories matching the selected facets: OR within a key, AND across keys.
    var filteredMemories: [Memory] {
        guard !selectedFacets.isEmpty else { return memories }
        let byKey = Dictionary(grouping: selectedFacets, by: \.key)
        return memories.filter { memory in
            byKey.allSatisfy { key, values in
                values.contains { memory.facets.matches(key, $0.value) }
            }
        }
    }

    /// Home shelves (ADR 0016) — shown when not searching and no facet filter.
    var recentMemories: [Memory] { Array(memories.prefix(8)) }

    var mostUsedMemories: [Memory] {
        Array(memories.filter { $0.accessCount > 0 }
            .sorted { $0.accessCount > $1.accessCount }
            .prefix(6))
    }

    var staleMemories: [Memory] {
        let now = Date()
        return Array(memories.filter { Ranking.rotRisk(for: $0, now: now) > 0 }
            .sorted { Ranking.rotRisk(for: $0, now: now) > Ranking.rotRisk(for: $1, now: now) }
            .prefix(6))
    }

    var untaggedMemories: [Memory] { memories.filter { $0.tags.isEmpty } }

    // MARK: - CLI / integration install

    /// When set, the app presents the install confirmation sheet for this action.
    var pendingInstall: InstallKind?

    /// Runs the CLI shipped inside the app bundle. `nonisolated static` so the
    /// install sheet can run it off the main actor without blocking the UI.
    nonisolated static func runBundledEngram(_ arguments: [String]) -> (output: String, success: Bool) {
        // Bundled at Contents/Helpers/engram (not Contents/MacOS — "engram" would
        // collide with the app binary "Engram" on case-insensitive APFS).
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/engram")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return ("Couldn't find the bundled engram CLI at \(executable.path).", false)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let success = process.terminationStatus == 0
            return (output.isEmpty ? (success ? "Done." : "Failed.") : output, success)
        } catch {
            return ("Failed to run engram: \(error.localizedDescription)", false)
        }
    }
}
