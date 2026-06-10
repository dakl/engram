# 19. Tag-centric exploration: Tags list + bipartite tag-graph

- **Status:** Accepted
- **Date:** 2026-06-06
- **Deciders:** Daniel Klevebring

## Context

ADR 0018 shipped a Semantic **Map** (classical-MDS projection of the 512-d
embeddings) and a **Structure** lens (Louvain community icicle). Testing on the
real store exposed two problems the data-visualization specialist confirmed are
fundamental at this scale, not tuning bugs:

- **The Map collapses to a blob.** A single outlier memory dominates the top
  eigenvector, crushing the other ~74 points into a sub-pixel cluster. This is
  the defining failure of *global* projection (MDS ≡ PCA) on a few dozen dense,
  anisotropic contextual embeddings — and t-SNE/UMAP are *more work and less
  trustworthy* at N≈75 (phantom clusters; non-deterministic; no Swift UMAP). The
  honest on-device fix (force layout of the kNN graph) only pays off past several
  hundred memories.
- **The Louvain icicle's labels "read oddly"** (derived, not authored) — the
  exact problem the discovery doc flagged.

The owner thinks in **tags and projects**, and proposed an explicit graph whose
**edges mean something**: memories connected by shared tags. The specialist
endorsed this as *more explainable than any projection* and recommended the
**bipartite** form (tags as first-class clickable hubs).

## Decision

Pivot exploration to be **tag-centric and deterministic**. Three changes:

### 1. Structure → **Tags** lens (primary structural surface)
A native, faceted list of **all tags**: sections by facet (`type:` / `project:` /
`language:` / freeform — reusing `Facets`/`LensGrouping.byTag`), each tag a row
with a member count; expand a tag → its memories as `MemoryRow`s; click a memory
→ inspector. Deterministic, authored labels, no projection. Replaces the Louvain
icicle (`StructureView`/`ClusterCut` as a view driver). Louvain stays only for
optional coloring.

### 2. Map → **memory-memory shared-tag graph**
**Memories are the only nodes; an edge joins two memories that share a tag**
(idf-weighted and pruned per node, so a catch-all tag can't fuse the cloud into a
clique; ubiquitous tags >90% of memories are dropped first). Position alone shows
which memories cluster by their shared tags. Clicking a dot → inspector, and
**selecting a memory highlights it (accent fill + persistent ring) plus its
linked neighborhood while the rest of the graph dims** (the same dim/emphasis
pattern as search-highlight; selection takes visual priority on its node). Reuses
the existing `GraphCanvas` substrate (force layout, pan/zoom, hover, tap) via
`MemoryGraphBuilder`/`ForceDirectedLayout` — the embedding projection is no longer
the Map's basis.

**Amendment — bipartite tag-hub form trialed and dropped:** an earlier form used
two node kinds — **memory** nodes and clickable **tag-hub** nodes joined by
memory→tag spokes (a tag on N memories = one hub with N spokes). It shipped behind
a temporary "Hubs / Links" toolbar toggle for an A/B; **Links** (this
memory-memory graph) was picked and the bipartite path, the toggle, and the
`TagGraph` builder were removed.

**De-clutter without knobs (amendment):** only the **top ~8 hubs are labeled at
rest** (the rest reveal on hover / zoom-in), **ubiquitous tags (>90% of memories)
are auto-dropped**, and spokes are idf-weighted. The Map's toolbar **color-by**
(cluster/source/type) and **frequency-cutoff slider** were **removed**: on a
tag-graph *position already encodes grouping*, so coloring dots re-encodes the
same thing (and the 12-color palette cycles past 12 groups), and the cutoff
slider was inert across most of its range (Zipfian tag frequencies). Dots are a
single neutral color; **color is reserved for search-highlight** (matches pop in
the accent, the rest dim).

### 3. Clickable tags + source (navigation)
In a memory's row and inspector, **tags and `source` become tappable** → jump to
that tag/source in the Tags lens (source resolves to its `project:` facet). This
makes the whole app navigable: from any memory, pivot to "everything else like
this." Row selection vs chip-tap must be disambiguated (the chips are their own
tap targets, distinct from selecting the row).

### What's dropped / reused
- **Drop (from the live path):** the classical-MDS `SemanticProjection` as the
  Map's layout (a force-layout *similarity* map may return as a separate lens once
  the store is larger — explicitly deferred); the Louvain **icicle** as a primary
  surface.
- **Reuse:** the `GraphCanvas`/`SceneDriver` interaction substrate (now driven by
  the bipartite layout); `MemoryGraphBuilder`'s **idf** machinery (to weight/rank
  tag edges); `Facets`/`LensGrouping.byTag` (Tags list); `Communities` (coloring
  only); the `selection → inspector` contract.

### Lenses after this change
**List · Tags · Map · Activity** (Map = the memory-memory shared-tag graph).

## Consequences

**Positive**
- Both new surfaces are **explainable and deterministic** — every grouping/edge
  has an authored reason (a tag), fixing the two things the owner disliked (the
  abstract blob and the odd derived labels).
- Tags list (folded) and tag-graph (unfolded) are the same structure two ways —
  coherent. Clickable tags/source make memories a navigable web.
- High reuse; the only real new work is the bipartite layout + the Tags list.

**Negative / trade-offs**
- Loses *semantic* adjacency that crosses tags (similarity the embeddings capture
  but tags don't). Mitigated by per-item "related items" later; the similarity map
  can return at larger N.
- The tag-graph can still clutter if many tags are very common; needs idf-based
  de-emphasis/omission of high-frequency tags.
- Nested tap targets (select-row vs tap-chip) need careful SwiftUI handling.

## Build order
1. **Tags lens:** facet-sectioned tag list → expand → memories; click → inspector.
2. **Clickable tags + source** in `MemoryRow` + inspector → focus that tag in Tags.
3. **Map → bipartite tag-graph:** memory+tag nodes, force layout on the canvas,
   tag-hub click → Tags, idf de-emphasis of common tags.
4. Rename `Section` `structure → tags`; retire the MDS projection from the Map;
   delete/retire `SemanticProjection` + `ClusterCut` view usage (keep or remove
   per cleanliness).
5. Docs: README, CLAUDE.md, ADR index; supersede 0018's Map/Structure.

## Related
**Supersedes the Map + Structure decisions of ADR 0018** (the Activity Table and
the overall native shell, ADR 0016/0017, stand). Realizes the discovery doc's
"faceted, tag-first, deterministic" direction. Produced with the
`collection-visualization-scientist` + `macos-swiftui-engineer` subagents.
