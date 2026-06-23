# 0023 — Session-scoped recall re-injection cooldown

- **Status:** Accepted
- **Date:** 2026-06-22
- **Deciders:** Daniel Klevebring

## Context

The recall hook (`engram hook recall`, ADR 0005/0021) is **stateless per prompt**:
on every `UserPromptSubmit` it hybrid-searches with the prompt as the query and
injects whatever clears the confidence gate (`RecallGate`). The gate answers "is
this memory topically relevant to *this* prompt?" — which is the right question
for a single prompt, but the wrong one across a session.

A user reported that in a session *about* Engram, a single memory ("X uses Engram
for Claude Code memory") was injected into ~30–40% of prompts (2–3 of 7–8) —
always the same memory. That's the gate working as designed: the prompts were all
topically on-subject, so the memory cleared the bar every time. But re-injecting
the **same** memory across a session adds no new information after the first time;
it wastes context and reads as spam.

The retrieval-activity ledger (ADR 0015) already records one row per injected
memory (`memory_id`, `source`, `query`, `at`) — it was missing only a session
dimension, so the hook had no way to know "did I already show this memory in this
session?"

## Decision

**Suppress re-injecting a memory that was already injected via recall in the same
session within a cooldown window.** Concretely:

- Add a `session_id TEXT` column to the `retrievals` ledger (additive migration,
  mirroring `addMissingColumns`) plus an index on `(session_id, memory_id, at)`.
  The recall hook reads `session_id` from the Claude Code hook payload and passes
  it to `recordRetrieval`.
- After the confidence gate selects the confident memories, the hook drops any
  that were already injected via `source = recall` **in this session** within the
  last `recallReinjectionCooldown` (default **30 minutes**). Whatever remains is
  injected and recorded (with the session id); if nothing remains, the hook stays
  silent, exactly as for an off-topic prompt.
- Suppression is **scoped to recall and to the session**. Manual `engram fetch`
  and the `session-digest` / `verify-context` hooks are unaffected. A genuinely
  new session (or the same memory after the cooldown elapses) can surface it
  again — so a long session still gets a periodic refresh rather than total
  one-shot suppression, which matters because earlier context can be compacted
  away.

**Cooldown shape — time vs. prompts.** A prompt-count cooldown ("not within the
last N prompts") maps more directly to the report, but it requires threading a
per-session prompt index (the reflection-nudge counter) onto every ledger row.
Time-based needs only the one `session_id` column and no coupling to the nudge
counter, and it fixes the reported scenario equally well (the repeats were
seconds-to-minutes apart). We ship **time-based** for v1; prompt-based remains a
clean future refinement if 30 minutes proves too coarse.

## Consequences

- The most common annoyance — the *same* memory on most prompts of an on-topic
  session — goes away, without narrowing recall breadth: other memories still
  surface normally, and the gate/embedder calibration (ADR 0021) is untouched.
- The change is confined to the ledger schema, `recordRetrieval`, one new query,
  and the recall hook. New DBs get the column in `CREATE TABLE`; existing DBs get
  it via the additive migration. The decoupling from ranking (ADR 0005/0015) is
  preserved — this only reads/writes the retrieval ledger.
- The injection ledger now carries `session_id`, which also unlocks a
  **session-aware eval metric** (a "redundant re-injection rate" over a multi-prompt
  session) — today's `engram-eval` is per-query (ADR 0021) and structurally can't
  see this. That metric is follow-up work, not part of this change.
- Trade-off: a memory shown once early in a very long session could be compacted
  out of context and not reappear until the cooldown lapses. Accepted for v1; a
  transcript-aware check ("is it still in context?") is a possible later refinement.
