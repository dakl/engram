# 1. Memory integration strategy: gated automatic recall + model-driven store

- **Status:** Accepted — the recall surface (SessionStart digest + `/recall`)
  is **superseded by [ADR 0005](0005-recall-via-gated-per-request-hook.md)**; the
  store decision (model-driven `/remember`) still stands.
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring

## Context

Engram exists so Claude Code can store and retrieve memories. The open question
was *how* to wire that into Claude Code: hooks, skills, or some inject/extract
mix. The two directions turn out to have **asymmetric ergonomics**:

- **Recall has a discovery problem.** Claude cannot ask for a memory it doesn't
  know exists. Pure model-driven recall (a skill/tool the model chooses to call)
  silently misses relevant context — the model doesn't know what it's missing.
  Automation is the only thing that closes this gap.
- **Store has a judgment problem.** Deciding *what is worth keeping* needs a
  model in the loop. A hook that fires on every `Stop`/`SessionEnd` would store
  conversational garbage. Storage wants intent.

A naive every-turn `UserPromptSubmit` recall hook (the initial implementation)
also injects context unconditionally, which over-signals: weak matches read as
authoritative. With the current `NLEmbedding` backend, similarity scores bunch
tightly (~0.68), so unfiltered injection is especially noisy.

The doobidoo `mcp-memory-service` validates a split design in practice: it does
automatic recall via a **`SessionStart`** hook with **tag + recency filtering**
("tag-first filter … within last-2-weeks / last-month"), exposes
**model-driven `store_memory`**, and offers `retrieve_memory` / `recall_memory`
tools for on-demand deeper lookups. No auto-store hook.

## Decision

Split the integration by direction, and prefer the *calmer* automatic surface.

**Recall — automatic but scoped:**
- Inject a **`SessionStart` digest** (scoped "what I remember about this
  project" note) rather than an unconditional per-turn dump.
- **Gate what gets injected** by relevance: a minimum blended score
  (`Ranking.score`) and/or recency window, capped at a small number of items.
- **Soft framing** ("possibly relevant notes; ignore if off-topic"), so
  injected memories are advisory, not authoritative.
- Provide an **on-demand recall path** (CLI / skill) for deeper mid-session
  lookups when Claude chooses to dig.

**Store — model-driven:**
- Storing happens through a **skill** (e.g. `/remember`) that calls
  `engram store`, invoked when Claude judges something is worth keeping.
- **No auto-store hook** on `Stop`/`SessionEnd`.

## Consequences

**Positive**
- No discovery gap: the baseline recall surfaces without Claude having to ask.
- No stored garbage: every write passes a judgment step.
- Low noise and low token cost: gating means most of the time nothing is
  injected, and the automatic surface is once-per-session, not per-turn.

**Negative / trade-offs**
- Recall beyond the session digest depends on Claude choosing to invoke the
  on-demand path — some relevant memory may still go unsurfaced mid-session.
- Skill triggering quality depends on a well-written `description`.
- Recall precision is still capped by embedding quality; gating thresholds are
  only meaningful once embeddings discriminate well (see follow-up).

**Follow-up actions**
- Replace the per-turn `UserPromptSubmit` recall hook with a `SessionStart`
  digest command (e.g. `engram hook session-digest`) plus score/recency gating
  in the recall path.
- Build the `/remember` (store) and `/recall` (on-demand retrieve) skills.
- Revisit gating thresholds after upgrading the embedder (Core ML
  sentence-transformer), since `NLEmbedding` scores are weak discriminators.
