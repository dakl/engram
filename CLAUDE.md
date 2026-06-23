# Engram

A local-first macOS memory app with a CLI that Claude Code hooks into to store
and recall content. See `README.md` for architecture and build instructions.

## Layout

- `Sources/EngramCore` — domain models, store, embeddings, ranking (the brains)
- `Sources/EngramCore/RecallGate.swift` — the recall confidence gate: decides which fetched memories are confident enough to inject on a prompt. Shared by the hook and the eval; presets `.current`/`.proposed`. `RecallText.swift` is the shared tokenizer (stopwords + lexical token overlap) used by both the gate and FTS.
- `Sources/EngramCore/RetrievalMetrics.swift` — pure retrieval-quality metrics (Recall@k, MRR, gate precision/recall, negative false-positive rate, injection precision) over labeled `QueryOutcome`s, plus the session-aware `SessionInjectionReport` (`evaluateSessions` / `firstTouchCoverage`) for the recall cooldown (ADR 0023).
- `Sources/engram-eval` — offline retrieval eval harness (`swift run engram-eval`): seeds a temp store from `Resources/corpus.json` + `queries.json`, runs each prompt through `fetch`, applies `RecallGate` configs, and prints a current-vs-tightened comparison (ADR 0021). It then replays `Resources/sessions.json` (ordered on-topic prompt sequences) through the gate + the real session cooldown and prints the **session-aware injection** metric — redundant re-injection rate with vs without the cooldown, plus first-touch coverage (ADR 0023). `--distances` dumps per-kind distance separability; `--record` appends a per-run JSON file (git sha + embedder signature + host + metrics, incl. the `sessions` block) under `eval/runs/`. Numbers are embedder/machine-dependent — it's a relative A/B, not a benchmark.
- `Sources/engram` — the `engram` CLI (store / fetch / stats / activity / hook)
- `Sources/CSQLite` — vendored SQLite + sqlite-vec (static C target)
- `Sources/engram/Setup.swift` — install logic (`engram install` / `engram setup`); the single source of truth for installing the CLI, hook, and skills. `engram install` symlinks `/usr/local/bin/engram` → the running binary
- `Engram/Engram/PrivilegedInstaller.swift` — app-side privileged install (ADR 0022): runs the symlink through the Apple-signed `/usr/bin/osascript` (`do shell script … with administrator privileges`) for one password dialog, no persistent helper; backs the toolbar **Install CLI** button
- `Engram/` — the Xcode SwiftUI app (thin shell over `EngramCore`); not sandboxed (ADR 0003)
- `Engram/Engram/SettingsView.swift` — Settings window (⌘,) with the Sparkle-backed Updates pane (ADR 0010)
- `Engram/Engram/ContentView.swift` — the native `NavigationSplitView` shell: sidebar (lenses + facet filters), detail container, one toolbar, trailing inspector (ADR 0016)
- `Engram/Engram/DesignSystem.swift` — shared tokens (`Typo`/`Space`/`Radii`), chip components, and the canonical `MemoryRow` (ADR 0016)
- `Engram/Engram/LensToolbar.swift` — per-lens contextual toolbar controls (Map color-by + tag-frequency cutoff, activity lookback) (ADR 0016/0018/0019)
- `Engram/Engram/MemoryInspector.swift` — trailing inspector that views/edits the selected memory; replaces the old modal editor sheet (ADR 0016)
- `Engram/Engram/FacetedHomeView.swift` — `ListDetail`: the List lens content (Top Hit + shelves / filtered list) in a native `List`; rows carry tappable tag/source chips (ADR 0013/0014/0016/0019)
- `Engram/Engram/TagsView.swift` — the Tags lens: a native `List` of all tags grouped by facet (TYPE/PROJECT/LANGUAGE/TAGS), each row a tag + member-count badge expanding to its `MemoryRow`s; click→inspector, tag/source chips→focus; honors `model.focusedTag` (scroll-to + expand) (ADR 0019)
- `Engram/Engram/MapView.swift` — the Map lens: a **memory-memory shared-tag graph** on the reused canvas substrate — memories are nodes, an edge joins two that share a tag (idf-weighted/pruned via `MemoryGraphBuilder`/`ForceDirectedLayout`, ubiquitous tags dropped); pan/zoom/hover, click dot→inspector; selecting a memory highlights it (accent + ring) and its neighborhood while dimming the rest (ADR 0019). The bipartite tag-hub form was trialed and dropped.
- `Sources/EngramCore/TreeOutline.swift` — pure builder turning a `DendrogramNode` clustering result into outline `TreeNode`s with cut-coloring (legacy; superseded UI removed in ADR 0018)
- `Engram/Engram/ActivityView.swift` — the Activity lens: a unified timeline of reads (recall/search/fetch/…) **and** writes (store/update/delete) as a native sortable `Table` backed by `MemoryStore.activity()`; lookback lives in the toolbar (ADR 0015/0016/0017/0020)
- `Sources/EngramCore/Facets.swift` — pure parser splitting tags into `key:value` facets vs freeform; folds `source` into `project` (ADR 0013)
- `Engram/Info.plist` — partial plist merged into the generated one; carries the Sparkle `SU*` keys (custom keys can't go through `INFOPLIST_KEY_*`)
- `Engram/scripts/bundle-cli.sh` — build phase that bundles the CLI into the app
- `scripts/release.sh` + `scripts/bump_version.py` — local `make release-*` flow: gate, bump, tag, push (ADR 0010)
- `scripts/update_appcast.py` — prepends a release entry to `docs/appcast.xml` (run by CI; stdlib-only so the runner needs no uv)
- `.github/workflows/release.yml` + `.github/ExportOptions.plist` — CI that signs, notarizes, and publishes a release (ADR 0010)
- `docs/` — GitHub Pages site: `index.html` (landing) + `appcast.xml` (the Sparkle feed)
- `docs/adr/` — Architecture Decision Records

## Architecture Decision Records

**Significant architectural decisions MUST be captured as an ADR in `docs/adr/`.**
This includes anything that changes service/module boundaries, storage or sync
strategy, the Claude Code integration model (hooks vs skills vs tools), the
embedding backend, or other choices that are hard to reverse.

- Before implementing such a change, write (or update) the relevant ADR.
- Follow the Nygard format documented in `docs/adr/README.md`; number
  sequentially and add the entry to the index.
- ADRs are immutable once Accepted — supersede with a new ADR rather than
  rewriting history.
- Day-to-day, reversible changes (bug fixes, refactors, UI tweaks) do **not**
  need an ADR.

## Documentation

**Keep docs in sync with the code as part of every change** (ADR 0002). When a
change alters behavior, structure, commands, or a decision, update the relevant
docs in the same change: `README.md`, this file, the ADRs + their index,
`docs/ROADMAP.md`, and the skill descriptions when the CLI surface changes. Docs
are part of "done", not a follow-up.

## Conventions

- Run `make test` after changing `EngramCore` or the CLI.
- Install/refresh the CLI with `make install` — Xcode's "Run" builds only the app, not the `engram` CLI.
- Build the app with `make app` (or open `Engram/Engram.xcodeproj` in Xcode).
- Conventional Commits for commit messages and PR titles.
