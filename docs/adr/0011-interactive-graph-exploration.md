# 11. Interactive multi-lens graph exploration + warm adaptive theme

- **Status:** Superseded by 0018
- **Date:** 2026-06-03
- **Deciders:** Daniel Klevebring, Claude

## Context

ADR 0007 delivered the memory graph as **one** derived graph (semantic + shared-tag
+ shared-source blend) plus a Louvain community hierarchy, rendered as a single
read-only force-directed view, and named two more planned views (clustering,
tree). ADR 0009 made the force layout a hand-rolled, swappable engine.

We now want the graph to be the **primary surface for exploring memories**, not a
static diagram. Concretely: several "lenses" that each answer a different
question (what's related? what topics? which projects? what did I learn when? how
does it nest?), interactive controls (pan/zoom, lens switching, tap-to-open,
attribute encoding), continuity between lenses, and a **warm, inviting** visual
identity in both light and dark appearances.

This extends 0007's "three views over one pipeline" into a general lens system,
and adds a theming layer the original view never had (it used saturated system
accent colours on a stark background, which reads clinical).

## Decision

**1. A `GraphLens` selects how the same memories are drawn.**
Within the existing Graph view mode, a picker switches between:

- `constellation` — relatedness communities (the ADR 0007 force graph), default.
- `tags` — tags as hub nodes; memories orbit the tags they carry.
- `sources` — memories grouped into labelled territories by `source` (repo/project).
- `timeline` — memories laid along a time axis by `createdAt` (a "river").
- `tree` — the Louvain `Cluster` hierarchy as a dendrogram, **memories as leaves**.

**2. Every lens derives from the existing substrate — no schema change.**
Lenses are pure functions in `EngramCore` over `memories` + `MemoryGraph` +
`Cluster` (tag index, source grouping, time ordering, tree from `Cluster`), each
unit-tested. This preserves 0007's "derive on demand, no `relations` table"
stance.

**3. Layout is per-lens, behind the swappable layout abstraction (ADR 0009).**
Constellation / tags / sources use the force engine (with group cohesion);
timeline and tree use deterministic layouts (time-axis; radial/indented
dendrogram). All produce `[UUID: SIMD2<Double>]` so the renderer stays uniform.

**4. Switching lenses animates node positions** (interpolate previous → next) so
exploration feels continuous — nodes glide, never teleport.

**5. Attribute encoding.** Node size/glow can encode a chosen attribute (access
count, recency, or rot-risk per ADR 0008), as a toggle that applies across
lenses, so "hot" vs "fading" memories read at a glance.

**6. Warm adaptive theme.** A single curated warm palette, defined as
appearance-adaptive colours (dynamic `NSColor` providers — no asset-catalog
churn), gives a parchment light theme and a warm-night dark theme. Background,
node fills/glow, edges, halos, and label pills all draw from this one theme, which
follows the system appearance.

**7. Rendering stays SwiftUI `Canvas` + `TimelineView`** (ADR 0007/0009); no new
third-party dependency.

## Consequences

**Positive**
- The graph becomes an exploration tool: multiple meaningful reads of the same data.
- Cohesive, warm visual identity in both appearances.
- All lenses are pure, derived, and testable — no migration, consistent with 0007.
- Reuses the force engine and the one-pipeline philosophy; theme is single-sourced.

**Negative / trade-offs**
- More layout code we own (timeline, radial tree) and more Canvas draw routines;
  managed by keeping each lens's derivation in `EngramCore` and its draw routine
  isolated in the view.
- The O(n²) force cost (ADR 0009) is unchanged; the new deterministic layouts are
  cheaper, but force-based lenses still need spatial partitioning if the store
  grows to thousands of nodes.
- Theme correctness across light/dark must be eyeballed; it can't be unit-tested.

**Supersession.** This **supersedes ADR 0007's specific enumeration** of "three
read-only views (force / clustering / tree)" by generalising to the lens system
above (0007 status updated to note this). ADR 0007's data pipeline (the blended
graph + Louvain hierarchy, derived on demand) and its read-only stance **stand
unchanged**; ADR 0009's swappable layout engine stands and is extended with the
deterministic layouts.
