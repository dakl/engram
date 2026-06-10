# 18. Collection exploration: Semantic Map + Structure lens

- **Status:** Accepted
- **Date:** 2026-06-06
- **Deciders:** Daniel Klevebring

## Context

The Tree and Graph lenses both failed to let the user *explore* the collection:

- The **Graph** drew blended similarity as a node-link **hairball** — at ~75
  near-uniform edges there's no load-bearing topology, so it's a pretty mesh that
  answers nothing. Force-directed graphs are legible only when edges are sparse
  and *meaningful*; pure similarity wants **position, not edges**.
- The **Tree** (HAC dendrogram → outline) surfaced the **binary merge order**
  ("65→63→62 memories") — an algorithm artifact — and discarded the one
  informative axis (merge *height* = how distinct a split is).

A data-visualization specialist and the macOS architect proposed replacements
grounded in the data (every memory has a 512-d `NLContextualEmbedding`; Louvain
communities are already computed *with labels*; HAC, force layout, and a mature
interactive `Canvas` substrate already exist). The owner chose the recommended
pair.

## Decision

Replace the **Tree** and **Graph** lenses with two complementary, interactive
lenses: a **Semantic Map** (neighborhoods) and a **Structure** view (taxonomy).

### 1. Semantic Map (primary explorer)
A zoomable canvas where each memory is a dot and **on-screen distance ≈ semantic
distance** (no resting edges). Communities (reusing `Communities.louvain` + its
labels) render as soft colored regions with floating labels.

- **Projection:** a pure, deterministic **classical MDS / PCA** to 2-D in
  `EngramCore` (`SemanticProjection`, unit-tested like the other algorithms) — no
  new deps, no network, O(n²) which is fine at hundreds–low-thousands. (UMAP/t-SNE
  are *not* needed at this scale; revisit only past ~1–2k items.)
- **Rendering:** reuse the existing `GraphCanvas` substrate (pan/zoom, hover
  tooltip, tap, world↔view transform, convex-hull region halos + labels,
  off-actor `SceneDriver` morph) — the Map is a new *layout* fed into the same
  canvas, not a new view.
- **Interaction verbs:** search-to-highlight (the global `.searchable` lights up
  matches, dims the rest); hover-peek; **click → inspector** (the existing
  `selectedMemory` contract); **lasso/marquee region-select** → a highlighted
  `Set<UUID>` with a count + clear (the verb both old views lacked);
  **find-similar** (draw rays to a dot's sqlite-vec KNN on demand — edges as a
  transient query, never the resting state); **semantic zoom** (titles appear
  when zoomed in); facet filters from the sidebar dim non-matching dots.
- **Controls (toolbar):** an Inspect/Select mode toggle and a color-by
  (cluster / source / type) picker; "Clear selection" when a region is selected.

### 2. Structure (the Tree, done right)
An **icicle** of the **Louvain community hierarchy** (`model.clusters` — the same
source the Map colors by) with a **depth** control (default the top level): depth 1
shows the handful of top-level communities; deeper depths reveal their
sub-communities. Block size ∝ member count, colored to match the Map; labels use
the distinctive count×idf labeler (`Communities.distinctiveLabel`). Click a member
→ it opens in the inspector. (Embedding HAC was tried here first but chained the
dense vectors into one giant cluster, so it was dropped from this view in favor of
the same communities the Map already shows.)

### 3. What's dropped / reused
- **Drop:** the node-link constellation **edge rendering** and the
  Sources/Tags/Timeline **graph lenses** (Sources/Tags are facet filters — already
  in the sidebar; Timeline overlaps Activity); the **dendrogram outline**
  (`TreeView`). The blended `MemoryGraph` edge set is no longer *drawn* (it stays
  available only if a future *typed-relations* knowledge graph is built — the one
  case where edges are the point).
- **Reuse:** embeddings (`embeddingVectors`), Louvain + labels (→ Map coloring +
  region labels **and** the Structure icicle), the force layout (optional
  projection refiner), sqlite-vec KNN (→ find-similar), and the whole `GraphCanvas`
  interaction substrate + the `onSelect → selectedMemory → .inspector` wiring.

### 4. Lenses after this change
Sidebar lenses become **List · Map · Structure · Activity** (Graph/Tree removed).

## Consequences

**Positive**
- Replaces a hairball + a merge-ladder with two purpose-built, *interactive*
  surfaces — neighborhoods (Map) and taxonomy (Structure).
- Very high reuse: the projection is the only substantial new algorithm; the Map
  is a re-layout of the existing canvas; Structure is the Louvain hierarchy + a
  depth control.
- Lasso/brush, find-similar, and semantic zoom are real exploration verbs the app
  lacked.

**Negative / trade-offs**
- At today's **~75 memories a 2-D projection can read as a vague blob** — it
  earns its keep as the store grows; Structure reads clearly at any size, which is
  why both ship.
- O(n²) MDS / O(n³) HAC are comfortable to ~1–2k items; beyond that needs
  landmark-MDS / a Barnes–Hut quadtree (deferred — years away for a personal store).
- New interaction mode (Select) adds a small mode toggle.

## Build order
1. `EngramCore`: `SemanticProjection` (classical MDS/PCA) + tests.
2. Extract a reusable map canvas from `GraphCanvas`; add the Map lens fed by the
   projection, colored/region-labeled by Louvain; wire search-highlight + click→
   inspector + hover (reused).
3. Add lasso/marquee select + semantic-zoom titles + find-similar rays; Map
   toolbar controls.
4. Structure lens: icicle + depth control over the Louvain community hierarchy;
   click→inspector.
5. Update `Section` enum (List/Map/Structure/Activity); delete `TreeView`, the
   graph lenses + constellation edge rendering; fold Sources/Tags into facets.
6. Docs: README, CLAUDE.md, ADR index; supersede 0011 + 0017.

## Related
**Supersedes ADR 0011** (interactive multi-lens graph exploration) and **ADR 0017**
(native Tree outline). Lives inside the ADR 0016 shell (lenses in the sidebar,
selection → inspector, system palette; `GraphTheme` is now data-color only). The
reusable `.claude/agents/collection-visualization-scientist` + the other designer/
engineer subagents produced this.
