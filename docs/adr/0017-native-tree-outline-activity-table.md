# 17. Native lens internals: outline Tree + Table Activity

- **Status:** Accepted (Tree outline superseded by 0018; Activity Table stands)
- **Date:** 2026-06-06
- **Deciders:** Daniel Klevebring

## Context

ADR 0016 moved the app to a native `NavigationSplitView` shell. The List lens now
reads as native, but the **Tree** and **Activity** lenses still feel foreign — they
reimplement, by hand, structure the platform provides:

- **Tree** (`DendrogramView`) is a hand-stroked `Canvas` dendrogram beside a custom
  `VStack` of `Button` rows, with its own warm `GraphTheme` backdrop, colored hover,
  fixed row height, re-implemented titles, and no native selection/keyboard nav.
- **Activity** is a `List` whose rows are a hand-built table (fixed-width timestamp
  column + a fixed-width colored `SourceBadge` pill + title/query), with no column
  headers and no sorting.

Two design specialists independently reached the same conclusion: hand it to the
system's own collection views.

## Decision

### Tree → native outline (`List` + `OutlineGroup`)
Render the hierarchical cluster tree as a native outline (the Finder/Xcode-navigator
pattern), `.listStyle(.sidebar)`:
- **Cluster rows** disclose/collapse (native triangles); each shows a `ClusterDot`
  (community color = data), a label, and a **member count** (`.badge`), with the
  merge **height** as trailing `Typo.meta` — preserving the dendrogram's one unique
  signal (cluster distance) without the drawn brackets.
- **Leaf rows** are the canonical `MemoryRow` + a leading `ClusterDot`, so a memory
  looks identical in Tree and List.
- **Selection** uses `List(selection:)` → `model.selectedMemory` → the inspector,
  like every other lens. Linkage/metric controls stay in Settings ▸ General.
- A pure `TreeOutline.build(...)` in `EngramCore` builds the outline node model from
  the existing clustering engine, reusing the cut-coloring logic; the **vertical
  dendrogram geometry** (`DendrogramLayout` vertical build + `DendrogramView`) is
  deleted along with its tests.

### Activity → native `Table`
Render the retrieval timeline as a `Table` with sortable `TableColumn`s — **Time**,
**Source**, **Memory**, **Query** — defaulting to reverse-chronological, with a
`selection:` binding → `model.selectedMemory`. The `SourceBadge` becomes tinted
**eyebrow text** (no fixed-width pill), its hue drawn from the shared data palette
via a `RetrievalSource.colorIndex`. The hand-built `ActivityRowView` is deleted.

### Shared craft
Both lenses converge on the List family's tokens (`DesignSystem.swift`): titles in
`Typo.rowTitle`, metadata in `Typo.meta`/`Typo.eyebrow`, `Space`/`Radii` constants,
selection as `Color.accentColor.opacity(0.12)`, and **color = data only** (the
`ClusterDot` / source hue is the lone color per row; chrome is system grey/material —
no warm backdrops, no colored hover, no fixed pill columns). The `.padding(Space.xl)`
that inset Tree/Activity in `DetailContainer` is removed so they fill the detail
column edge-to-edge like the List lens.

## Consequences

**Positive**
- Tree and Activity gain native disclosure, selection, keyboard nav, hover/focus,
  and (Activity) sortable resizable columns — for free, and consistent with List.
- Less bespoke code to maintain (a `Canvas`, a custom layout pass, hand-rolled rows
  all deleted); rows reuse the shared `MemoryRow`/`ClusterDot`.
- All four lenses now read as one family.

**Negative / trade-offs**
- The dendrogram's *visual* encoding of merge height (the bracket geometry) is gone;
  height survives only as a per-cluster-row number. If that proves too lossy, a small
  read-only height affordance can be added later — but the full canvas is not coming
  back.
- Deletes `EngramCore` vertical-layout code + tests (replaced by `TreeOutline` tests).

## Related
Realizes ADR 0016's "every lens native" intent for Tree and Activity, and
**supersedes the vertical-dendrogram Tree** from ADR 0011 (the beta Graph canvas —
a genuine custom visualization — is unaffected and stays behind the beta toggle).
The reusable `.claude/agents/` designer + `macos-swiftui-engineer` subagents
produced and built this.
