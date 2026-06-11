# Engram Roadmap

Captured wishes and their status. Significant/architectural items get an ADR in
`docs/adr/` before implementation (see `CLAUDE.md`).

## Done

### Service / repo summaries (behavior)
When a conversation establishes what a service or git repo does, Claude stores
(or updates) a 1–2 sentence summary tagged `service` + repo name. Encoded in the
`/remember` skill.

### Update memories in conversation
`engram update <uuid> [--content …] [--tags …] [--source …]` re-embeds and bumps
`updated_at`. The `/remember` skill recalls an existing memory by id and updates
it instead of creating a near-duplicate.

## Planned (ADR-pending)

### 1. Memory freshness / re-scan
*Problem:* facts go stale as code and decisions change.

Ideas to explore:
- A `last_verified_at` field separate from `updated_at`; surface "stale" when a
  memory hasn't been verified in N days, or when its `source` repo's `HEAD` has
  moved since it was written.
- `engram rescan <repo>` — re-derive service summaries from the current repo
  state and `update` the matching memories.
- Optional confidence/decay so unverified memories rank lower over time.

*Open questions:* what counts as "stale"; how much to automate vs. prompt the
user; where re-derivation logic lives (CLI vs. app vs. a Claude skill).
→ **ADR before building.**

### 2. Contradiction detection + GUI flagging
*Problem:* two memories may disagree (e.g. "prod project is X" vs "…is Y").

Ideas to explore:
- Detection: high semantic similarity **+** a disagreement signal. Embedding
  similarity alone finds *related*, not *contradictory* — likely needs an
  LLM-judged pass (batch job) or a negation/conflict heuristic.
- Storage: a `relations` table (see graph below) with a `contradicts` edge.
- GUI: badge conflicting memories and offer a "resolve" action (keep one /
  merge / mark superseded).

*Open questions:* detection accuracy/cost; when to run (on store, on a schedule,
on demand). → **ADR before building.**

### 3. Bundle our own embedder (replace NLContextualEmbedding + fallback)
*Problem:* the embedder is Apple's `NLContextualEmbedding`, whose weights
download on demand — so the app needs a degraded `word-512` fallback for the
gap, the two backends live on different distance scales (forcing the
embedder-relative gate of ADR 0021), and embeddings are non-deterministic across
machines (the `engram-eval` numbers can't be a cross-machine benchmark).

Ideas to explore:
- Bundle a small sentence-transformer (e.g. `all-MiniLM-L6-v2`, 384-dim) via
  Core ML, or a quantized embeddings runtime; drop `NLContextualEmbedding` *and*
  the fallback entirely.
- Benefits: deterministic/reproducible vectors → stable, checked-in gate
  threshold and a real eval benchmark; no async asset download; one distance
  scale; likely better short-text retrieval (tighter than the ~0.1 contextual
  band).
- Costs: app size (+~25–90 MB), owning the runtime/conversion, revisiting the
  "no bundled model" spirit of ADR 0003/0004, and a re-embed migration (already
  supported via `signature` change, ADR 0012).

*Open questions:* model choice + license; Core ML vs. other runtime; size budget
for the notarized app. → **ADR (supersedes ADR 0012's backend) before building.**

### 3. Memory graph + UI inspection → **ADR 0007 (Accepted)**
*Problem:* memories are currently a flat list; relationships are implicit.

Design decided in [ADR 0007](adr/0007-memory-graph-view.md): one weighted graph
derived on demand (no schema change) from a blend of **semantic** (sqlite-vec
KNN), **shared-tag** (idf-weighted), and **shared-source** edges; **Louvain**
community detection on that graph yields a cluster hierarchy. Three read-only
views over the one pipeline — **force-directed graph**, **hierarchical
clustering**, and an **OutlineGroup tree** — all coloured by the same
communities. Graph/cluster logic lives in `EngramCore` (pure, unit-tested);
force layout is **hand-rolled** behind a `GraphLayoutEngine` protocol so it's
swappable ([ADR 0009](adr/0009-hand-rolled-force-layout.md) — Grape dropped: its
`ForceSimulation` product doesn't expose node positions publicly).

Generalised in [ADR 0011](adr/0011-interactive-graph-exploration.md): the single
force view becomes an **interactive, multi-lens exploration surface** — lenses
for relatedness (`constellation`), `tags`, `sources`, `timeline`, and a
hierarchical `tree` (memories as leaves), with animated transitions between them,
attribute encoding (size/glow by access/recency/rot-risk), and a **warm,
appearance-adaptive theme** (parchment by day, warm-night by dark). The 0007 data
pipeline and read-only stance stand; only the view enumeration is superseded.

Deferred to later ADRs: explicit edges (`supersedes`/`contradicts`, → #2) and
the `relations` table they need; temporal / co-access edges; an `engram graph`
CLI export. (The `graphify` skill is prior art worth looking at.)

*Remaining open questions:* the α/β/γ blend + Louvain resolution tuning; perf /
caching at thousands of nodes; how it interacts with CloudKit sync.

## Related future work
- **Notarized distribution** (ADR 0003): the bundled `engram` currently keeps
  its ad-hoc `swift build` signature (re-signing with the app identity is
  best-effort in the build phase). For Developer ID distribution, sign the
  embedded CLI with hardened runtime and notarize the app.
- CloudKit mirror + iOS companion (schema is already sync-ready).
- Stronger on-device embedder (Core ML sentence-transformer) — improves recall
  precision and would make the graph's semantic edges meaningful.
- Migrate the ~1412 doobidoo memories into Engram (needs re-embedding) — ADR 0002.
