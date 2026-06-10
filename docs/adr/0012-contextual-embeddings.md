# 12. On-device contextual embeddings via NLContextualEmbedding

- **Status:** Accepted
- **Date:** 2026-06-04
- **Deciders:** Daniel Klevebring, Claude

## Context

ADR 0004 chose Apple's `NLEmbedding.sentenceEmbedding` as the on-device embedder
behind hybrid retrieval, and explicitly noted its weakness: it's a static
word/sentence model whose cosine similarities bunch around ~0.68, a poor
discriminator. That weakness is now the limiting factor for the graph/dendrogram
views (ADR 0011) — clusters are mushy because the underlying vectors barely
separate. Baking tags/source into the embedded text was considered but rejected:
it's a band-aid that doesn't fix the model and fights the (separate, tunable)
relatedness-weighting we want.

macOS 14 ships a strictly better option in the same framework:
**`NLContextualEmbedding`** — a transformer-based, multilingual *contextual*
embedding. It stays fully on-device with no third-party dependency or bundled
model; its assets download once on demand.

## Decision

**Replace `NLEmbedding` with `NLContextualEmbedding` as the embedder**, mean-pooling
its per-token vectors into one sentence vector.

- `Embedder` tries to `load()` the contextual model; if its assets aren't
  downloaded yet it kicks off an async `requestAssets` and **falls back to
  `NLEmbedding` for the current launch**, so nothing ever blocks. The next launch,
  with assets present, uses the contextual model.
- The backend is fixed for the lifetime of an `Embedder` instance (decided at
  init), so a single run never mixes vectors from two models or two dimensions.
- The embedding **dimension is now an instance property** (the contextual model's
  `.dimension`), not a hard-coded 512, and `Embedder` exposes a `signature`
  (backend + dimension).

**Migration: re-embed when the embedder changes.** The store records the
embedder `signature` in a `meta` table. When it differs from the current embedder
(a fresh upgrade, or assets becoming available between launches), the store drops
and recreates `vec_memories` at the new dimension and **re-embeds every memory**
from its stored content. This is a one-time, automatic background-ish cost at
launch; FTS/lexical search is unaffected.

**Tags/source stay out of the embedded text** — they remain a separate, tunable
relatedness signal (the weighting blend), not baked into the vector.

## Consequences

**Positive**
- Genuinely separable vectors → meaningful clusters, dendrograms, and recall.
- Still 100% on-device, no API keys, no third-party model bundling (ADR 0003/0004
  spirit intact); shared by the CLI and the app via the same `Embedder`.
- Re-embed-on-signature-change makes future embedder swaps safe and automatic.

**Negative / trade-offs**
- First run after upgrade re-embeds the whole store (one-time; O(memories)).
- First launch may use the weaker fallback until assets finish downloading, then
  re-embed on the following launch.
- Vector dimension is no longer a compile-time constant; the `vec_memories`
  schema is created from the live embedder dimension and rebuilt on change.
- Contextual embedding is heavier per call than the static model (fine at this
  scale; revisit batching if the store grows large).

**Supersession.** Supersedes ADR 0004's *embedder choice* (`NLEmbedding`); the
rest of ADR 0004 (FTS5 + sqlite-vec hybrid, RRF fusion) stands unchanged.
