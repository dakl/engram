# 4. Hybrid retrieval: lexical (FTS5/BM25) + semantic (sqlite-vec), fused with RRF

- **Status:** Accepted
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring

## Context

Semantic-only recall keeps failing on exactly the queries that matter: ones with
specific terms — "soundtrack graph", "uv", "es-platform-prod". The on-device
`NLEmbedding` vectors bunch scores tightly (~0.68) and don't discriminate, so an
on-topic memory loses to noise. (Observed live: "what does the soundtrack graph
service do?" ranked an unrelated note above the answer.)

Lexical (keyword) and semantic search fail in *opposite* places: BM25 excels at
rare tokens, proper nouns, and identifiers; embeddings excel at paraphrase and
concept. That complementarity is the textbook case for **hybrid search** — and
SQLite is already compiled with `SQLITE_ENABLE_FTS5`, so the lexical engine is
available with no new dependency.

## Decision

`fetch` runs **both** retrievers and fuses them:

- **Lexical:** an FTS5 table `memories_fts(memory_id UNINDEXED, content, tags)`
  with the `porter unicode61` tokenizer (stemming + unicode), kept in sync with
  the `memories`/`memory_tags` tables inside the same transactions as
  store/update/delete, and backfilled for pre-existing rows on migration.
- **Semantic:** the existing sqlite-vec cosine KNN.
- **Fusion: Reciprocal Rank Fusion (RRF).** `score = Σ 1/(k + rank_i)` over each
  result list (k = 60). RRF fuses by *rank*, so the incompatible scales (cosine
  distance vs BM25) never need normalizing, and it degrades gracefully when one
  side returns nothing.

The fused RRF value (normalized to 0–1) becomes the **relevance** signal, which
`Ranking` then blends with recency and frequency as before. `RankingConfig`'s
`semanticWeight` is renamed `relevanceWeight` to reflect that the signal is now
lexical+semantic, not semantic alone.

## Consequences

**Positive**
- Exact-term queries (the recurring failure) now hit via lexical, while
  paraphrase still works via semantic.
- Makes the embedder upgrade *less urgent*: lexical compensates for weak vectors.
- No new dependency — FTS5 was already enabled.

**Negative / trade-offs**
- The store now maintains a second index (the FTS table) that must stay in sync
  on every write; a bug there means stale lexical results.
- User query text must be sanitized into a safe FTS5 `MATCH` expression.
- RRF's `k` and the relevance/recency/frequency weights are now tunable knobs to
  get wrong.

## Follow-up
- A regression test guards the soundtrack-graph case (keyword match that
  semantic-only missed).
- Revisit weights once the embedder is upgraded (ADR-pending), since better
  vectors shift the lexical/semantic balance.
