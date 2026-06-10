import SwiftUI
import EngramCore

/// The app's native shell (ADR 0016): a `NavigationSplitView` whose sidebar holds
/// the lens switcher + (in List) the facet filters, whose detail column shows the
/// active lens, and whose trailing inspector shows the selected memory.
struct ContentView: View {
    @State private var model: EngramModel

    /// First-run flag (P1 #10). Persisted so the welcome sheet shows exactly once.
    @AppStorage("engram.hasOnboarded") private var hasOnboarded = false
    @State private var showWelcome = false

    /// Persist the selected lens so a relaunch lands where you left off (P2 #4).
    @AppStorage("engram.lastLens") private var lastLensRaw = EngramModel.Section.list.rawValue

    init(model: EngramModel? = nil) {
        _model = State(initialValue: model ?? EngramModel())
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            DetailContainer(model: model)
                .navigationTitle(model.section.title)
                .toolbar { detailToolbar }
                .inspector(isPresented: inspectorPresented) {
                    MemoryInspector(model: model)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
        }
        .searchable(text: $model.searchQuery, placement: .toolbar, prompt: "Search memories")
        .frame(minWidth: 720, minHeight: 520)
        .onChange(of: model.searchQuery) { _, _ in model.search() }
        .onChange(of: model.section) { _, new in lastLensRaw = new.rawValue }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { presented in if !presented { model.dismissError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.pendingInstall) { kind in
            InstallSheet(kind: kind, model: model)
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet(model: model, hasOnboarded: $hasOnboarded)
        }
        .task {
            // Restore the lens the user last had open (P2 #4).
            if let saved = EngramModel.Section(rawValue: lastLensRaw) { model.section = saved }
            // First launch with a live store and nothing dismissed yet: greet the user.
            if !hasOnboarded && model.storeAvailable {
                showWelcome = true
            }
        }
    }

    /// The inspector is open whenever a memory is selected; closing it clears the
    /// selection.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { model.selectedMemory != nil },
            set: { presented in if !presented { model.selectedMemory = nil } }
        )
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // Per-lens contextual controls (graph lens, activity lookback) sit here.
        LensToolbar(model: model)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.pendingInstall = .cli } label: {
                Label("Install CLI", systemImage: "terminal")
            }
            .help("Install the engram command-line tool")
            .accessibilityLabel("Install CLI")
            Button { model.pendingInstall = .integration } label: {
                Label("Hooks & Skills", systemImage: "sparkles")
            }
            .help("Install Claude Code hooks and skills")
            .accessibilityLabel("Install Hooks and Skills")
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload from the store")
            .accessibilityLabel("Refresh")
        }
    }
}

// MARK: - Sidebar

/// The navigation sidebar: a standard `List` (collapsible/resizable for free) of
/// lens rows, then — in the List lens — the facet filter sections, with an
/// ambient stats footer.
private struct Sidebar: View {
    let model: EngramModel

    var body: some View {
        List(selection: sectionSelection) {
            Section("Lenses") {
                ForEach(EngramModel.Section.visibleCases) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            if model.section == .list {
                ForEach(FacetKey.allCases, id: \.self) { key in
                    let values = model.facetCounts(for: key)
                    if !values.isEmpty {
                        Section(key.rawValue.uppercased()) {
                            ForEach(values, id: \.value) { entry in
                                facetRow(key: key, value: entry.value, count: entry.count)
                            }
                        }
                    }
                }
                if model.hasFacetFilter {
                    Button("Clear filters", systemImage: "xmark.circle") {
                        model.selectedFacets.removeAll()
                    }
                    .foregroundStyle(.tint)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { statsFooter }
    }

    private var sectionSelection: Binding<EngramModel.Section?> {
        Binding(
            get: { model.section },
            set: { if let section = $0 { model.section = section } }
        )
    }

    private func facetRow(key: FacetKey, value: String, count: Int) -> some View {
        let selected = model.isFacetSelected(key, value)
        return Label(value, systemImage: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .badge(count)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleFacet(key, value) }
    }

    private var statsFooter: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(model.stats.totalActive) memories").font(Typo.eyebrow)
            Text("\(model.stats.createdLast7Days) new this week · \(model.formattedDatabaseSize)")
                .font(Typo.meta)
                .foregroundStyle(.secondary)
            Label("On this Mac only — no cloud, no telemetry", systemImage: "lock.shield")
                .font(Typo.meta)
                .foregroundStyle(.tertiary)
                .help(PrivacyCopy.summary)
                .padding(.top, 2)
            if model.usingFallbackEmbedder {
                Label("Reduced recall — using fallback embeddings", systemImage: "exclamationmark.triangle")
                    .font(Typo.meta)
                    .foregroundStyle(.orange)
                    .help("The on-device contextual embedding model isn't available, so search is running on a simpler fallback. Recall quality is reduced.")
                if model.isReindexing {
                    Label("Re-indexing…", systemImage: "arrow.triangle.2.circlepath")
                        .font(Typo.meta).foregroundStyle(.secondary)
                } else {
                    Button("Re-index now") { model.reindex() }
                        .font(Typo.meta)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("Rebuild the embedding index — picks up the contextual model once its assets have downloaded, without restarting the app.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(.bar)
    }
}

// MARK: - Detail container

/// Routes the selected lens to its detail view — the single place the four modes
/// plug into the shared shell.
private struct DetailContainer: View {
    let model: EngramModel

    var body: some View {
        switch model.section {
        case .list:
            ListDetail(model: model)
        case .tags:
            TagsView(model: model)
        case .map:
            MapView(model: model)
        case .activity:
            ActivityView(model: model)
        }
    }
}

#Preview {
    ContentView(model: .preview())
}
