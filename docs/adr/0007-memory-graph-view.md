# 7. Memory graph: one derived graph + community hierarchy, three read-only views

- **Status:** Accepted — the force-layout engine (Grape) is **superseded by
  [ADR 0009](0009-hand-rolled-force-layout.md)** (hand-rolled, no dependency);
  the rest (derived graph, Louvain, three views, `GraphLayoutEngine` protocol)
  stands.
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring

## Context

Memories are a flat list; relationships between them are implicit (roadmap #3).
We want to *see* the structure — which memories cluster, which span projects,
which are semantically near. The `Memory` struct has **no relationship field**:
the signals available today are `tags`, `source`, and the 512-d `NLEmbedding`
vectors already stored in sqlite-vec (ADR 0004). So a graph view must *derive*
its edges from those, not read a stored edge set.

Three lenses are wanted: a **force-directed graph** (the web), a **hierarchical
clustering**, and a **tree** to browse. The risk is building three disconnected
features whose layouts disagree. The inspiration
([OutlineGroup](https://www.glucode.com/blog/posts/getting-started-with-swiftui-s-outlinegroup))
renders a *tree* — one parent per node — which fits a hierarchy but not the
many-to-many reality (a memory has several tags).

## Decision

### One pipeline, three lenses

Compute **one weighted graph once**, then render it three ways:

1. **Nodes** = active (non-deleted) memories.
2. **Edges** = a blend of three signals, each contributing weight:
   - **semantic** — sqlite-vec cosine KNN: for each node take its top-`k`
     nearest with distance below a cutoff. Per-node KNN keeps the graph sparse
     and avoids an O(n²) all-pairs pass (≈ `n·k` edges via the vector index).
   - **shared-tag** — memories sharing ≥1 tag. Weighted by tag-set overlap and
     **down-weighted by tag frequency** (inverse-document-frequency style) so a
     popular tag like `service` doesn't fuse everything into one clique.
   - **shared-source** — same `source` (repo/project). A flat weight,
     down-weighted for very large sources for the same anti-clique reason.
3. **Blend:** `weight = α·semantic + β·sharedTag + γ·sharedSource`, with α/β/γ in
   a `GraphConfig` mirroring `RankingConfig`. Each edge records *which* kinds
   fired (`Set<EdgeKind>`) so the UI can filter by edge type.
4. **Prune:** keep the top-`k` edges per node by blended weight and drop edges
   below a floor — sparse graph, fast layout, no hairball.

**Community detection** runs *on that blended graph* — **Louvain** (modularity
maximisation). Louvain is multi-level by construction: each pass merges
communities, so its passes *are* the cluster hierarchy. The output is a
`Cluster` tree (community → sub-community → memory leaf).

The three views are then renderings of these two artifacts:

- **Force-directed graph** → the nodes + blended edges, nodes coloured by their
  top-level community.
- **Hierarchical clustering** → the `Cluster` tree (e.g. treemap / nested
  bubbles).
- **Tree** → the same `Cluster` tree as an `OutlineGroup` disclosure list
  (community → sub-community → memory).

So "clustering" and "tree" are the same data viewed two ways, and the graph
agrees with both because it colours by the same communities.

### Derived on demand, not persisted (v1)

The graph and clusters are **computed on demand from existing data** (tags,
source, vectors). **No `relations` table, no schema migration.** v1 is
**read-only** (ADR-answered): click a node to inspect, pan/zoom/expand — no
mutation. A persisted edge table is only needed for *explicit* relations
(`supersedes`, `contradicts` — roadmap #2), which is out of scope here and gets
its own ADR when built.

### Logic lives in EngramCore

The brains go in `EngramCore`, the app stays a thin renderer:

```swift
// EngramCore — pure value types
public enum EdgeKind: Sendable { case semantic, sharedTag, sharedSource }
public struct GraphNode: Identifiable, Sendable { public let id: UUID; public let memory: Memory }
public struct GraphEdge: Sendable { public let a: UUID; public let b: UUID; public let weight: Double; public let kinds: Set<EdgeKind> }
public struct MemoryGraph: Sendable { public let nodes: [GraphNode]; public let edges: [GraphEdge] }
public struct Cluster: Identifiable, Sendable { public let id: Int; public let label: String; public let memberIDs: [UUID]; public let children: [Cluster] }

public struct GraphConfig: Sendable { /* α, β, γ, k, distance cutoff, edge floor */ }
```

- `MemoryStore` (the `actor` that owns the connection, ADR 0006) gains
  `public func graph(config: GraphConfig) async throws -> MemoryGraph` — it does
  the DB work (list memories, per-node KNN), then hands plain data to **pure,
  DB-free functions** for edge blending and Louvain so they're unit-testable
  without SQLite:
  - `MemoryGraphBuilder.blend(memories:neighbors:config:) -> [GraphEdge]`
  - `Communities.louvain(_: MemoryGraph) -> Cluster`
- These pure functions are seedable/deterministic for tests (e.g. a fixture with
  two obvious clusters must yield two communities).

### Force-layout: third-party engine behind our own protocol

Use **[Grape](https://github.com/SwiftGraphs/Grape)**'s `ForceSimulation`
module (Barnes–Hut + KDTree) for the physics, but depend on it **behind a
protocol** so the engine is swappable for a hand-rolled spring sim later
(matching the dependency-averse, vendor-everything style of the project):

```swift
// App layer — layout is presentation, not core
protocol GraphLayoutEngine {
    mutating func step()                       // advance the simulation
    var positions: [UUID: CGPoint] { get }     // current node positions
    var isSettled: Bool { get }
}
struct GrapeLayoutEngine: GraphLayoutEngine { /* wraps ForceSimulation */ }
```

We render nodes/edges ourselves with **SwiftUI `Canvas` + `TimelineView`**
(step until `isSettled`, then freeze), so swapping engines touches only the
physics, never the rendering or `MemoryGraph`.

### UI placement

A view-mode switch in the existing memories area of `ContentView` (segmented
`Picker`: **List · Graph · Clusters · Tree**), driven by `EngramModel`, which
caches the computed `MemoryGraph`/`Cluster` and recomputes on refresh or data
change. Reuses the existing model and search/detail surfaces.

### Alternatives rejected

- **Three independent views.** Duplicates logic and the layouts disagree
  visually. The shared pipeline is DRY and consistent.
- **Persist a `relations` table now.** Needs a schema migration for data we can
  derive for free; defer it to when *explicit* edges actually exist.
- **Agglomerative clustering on embeddings only.** A clean dendrogram, but it
  ignores tags/source — inconsistent with the blended graph the other two views
  show.
- **Grape's full SwiftUI graph view.** Faster, but couples rendering to the dep
  and forecloses the hand-rolled option that was explicitly wanted.
- **A fixed `source → tag → memory` taxonomy for the tree.** Trivial, but it's a
  hand-built hierarchy, not data-driven clusters.

## Consequences

**Positive**
- One computation feeds all three views; they always agree (shared communities,
  shared colours).
- No schema change, no migration — v1 rides entirely on existing data.
- Graph/clustering logic is pure and unit-tested in `EngramCore`; reusable by the
  CLI later (e.g. an `engram graph` export).
- Layout dependency is isolated behind a protocol — swappable without churn.

**Negative / trade-offs**
- New knobs to get wrong: α/β/γ blend, KNN `k`, distance cutoff, edge floor,
  Louvain resolution. Weak `NLEmbedding` vectors (ADR 0004) make the semantic
  edges noisier than the others — expect to lean on tags/source initially.
- A real third-party dependency (Grape) — the first in the project; needs
  vetting (licence, maintenance) and pins SwiftPM resolution.
- Recompute cost grows with memory count; fine at hundreds, will need caching /
  incremental update if the store grows large. Layout runs on the main actor's
  display loop — settle-then-freeze keeps it cheap.

## Follow-up

- Tune the blend against the real store once it renders; consider exposing the
  weights in the UI for exploration.
- When explicit relations land (roadmap #2: `supersedes`/`contradicts`), add a
  persisted edge source and a new `EdgeKind`, superseding the "derived-only"
  part of this decision with a fresh ADR.
- Possible `engram graph --format json|dot` CLI export reusing the same
  `MemoryGraph` (its own small ADR for the CLI contract).
