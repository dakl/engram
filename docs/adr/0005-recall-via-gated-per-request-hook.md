# 5. Recall via a gated, read-only, per-request hook (no /recall skill)

- **Status:** Accepted
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring
- **Supersedes:** the recall-surface decision in ADR 0001 (the store decision —
  the `/remember` skill — still stands).

## Context

ADR 0001 chose a `SessionStart` digest for automatic recall plus an on-demand
`/recall` skill. Two things since then changed the calculus:

1. **`/recall` was dropped.** A skill is a *nudge*, not a capability — Claude can
   run `engram fetch` regardless — and the automatic hook already solves the
   discovery problem. So `/recall` earned little, and removing it leaves
   `SessionStart`-only recall, which **can't cover mid-session topic shifts**
   (e.g. opening a session on `engram`, then asking about `soundtrack-graph`).
2. **Hybrid search + gating arrived (ADR 0004).** Better relevance plus a
   confidence gate defuse ADR 0001's reason for avoiding per-turn recall
   ("too strong a signal").

Implementing per-request recall also exposed a hazard: `fetch` marks returned
memories accessed, and `access_count` feeds `Ranking` — a **rich-get-richer
feedback loop** that a per-prompt hook would run away with (observed: a noise
memory hit `access_count = 15` purely from test queries).

## Decision

- **Recall runs on `UserPromptSubmit`** — before each request, using the prompt
  as the query. The prompt is a far better query than a project digest, and it
  covers mid-session topic shifts.
- **Read-only:** the hook calls `fetch(…, recordAccess: false)`, so automatic
  recall never inflates `access_count` (breaks the feedback loop).
- **Gated:** inject only confident matches — a lexical (keyword) hit or a tight
  semantic distance — capped at 3, with soft framing ("Possibly relevant
  notes… ignore if off-topic"). Off-topic prompts inject nothing.
- **`/recall` skill removed.** `/remember` (store) is unchanged.

## Consequences

**Positive**
- Covers mid-session topic shifts; quiet on off-topic prompts; no access inflation.
- One recall mechanism to reason about instead of two.

**Negative / trade-offs**
- Runs on every prompt (fast — local sqlite-vec + FTS5, <~100 ms).
- With weak `NLEmbedding`, the gate leans almost entirely on the **lexical** hit;
  the semantic-distance threshold is effectively dormant until the embedder is
  upgraded. Paraphrased queries with no shared keywords won't surface memories
  automatically (acceptable: silence beats noise for an auto-injected hook).
