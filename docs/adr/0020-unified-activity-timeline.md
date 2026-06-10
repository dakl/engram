# 20. Unified Activity timeline: reads and writes in one stream

- **Status:** Accepted
- **Date:** 2026-06-06
- **Deciders:** Daniel Klevebring
- **Relates to:** ADR 0015 (retrieval-activity ledger) — extends it; does **not**
  supersede it. ADR 0017 (Activity as a native `Table`) — the rendering is reused.

## Context

The Activity lens (ADR 0015/0017) shows only **retrievals** — when a memory was
*surfaced* (recall / session-digest / verify-context / fetch / search). Writing a
memory (`engram store`, an edit, a deletion) never appears, so the lens reads as a
recall log, not an activity log. The natural question "what happened here lately?"
can't be answered: the moment a memory was *created* is invisible.

The data already exists. Two ledgers were established earlier:

- **`retrievals`** (ADR 0015) — reads, with the query that surfaced them, decoupled
  from ranking.
- **`events`** (pre-0015 lifecycle table) — `created` / `accessed` / `updated` /
  `deleted`, one row per occurrence. `store()` already records `created` here; it
  only ever fed the stats counts, never the UI.

So "show stores in Activity" needs **no new capture** — only to read both ledgers
into one timeline.

`events.accessed` is deliberately **excluded**: it overlaps the `retrievals` ledger
(it fires on deliberate fetch/search) and is entangled with ranking (ADR 0005 /
0015). Including it would double-count reads and re-surface the coupling 0015 took
care to keep out of this view.

## Decision

- **The Activity lens reads both ledgers as one stream.** A new pure store method
  `activity(since:limit:)` `UNION ALL`s `retrievals` with the write rows of
  `events` (`created` / `updated` / `deleted`, never `accessed`), newest first.
- **A unified `ActivityKind`** (domain) is the display authority for a row: the
  five read sources (raw values aligned with `RetrievalSource`) plus `created` /
  `updated` / `deleted`. It owns the badge `label` (`created` reads as **STORE** to
  match the CLI verb), the `colorIndex` into the shared community palette (writes
  take indices 5–7, distinct from the five read hues), and an `isWrite` flag.
- **`ActivityEvent`** replaces `RetrievalEvent` as the row the timeline carries:
  `(id, memoryID, kind, query?, at)`. `query` is `nil` for writes. `id` is a
  ledger-prefixed string (`"r:<rowid>"` / `"e:<rowid>"`) so ids stay unique across
  the two `INTEGER PRIMARY KEY` tables.
- **`RetrievalSource` / `retrievals()` / `recordRetrieval` are unchanged.** Reads
  are still recorded exactly as in ADR 0015; only the *read-back* for the Activity
  view is unified. `RetrievalEvent` and `retrievals(since:source:)` remain for any
  retrieval-only consumer.
- **The CLI `engram activity`** uses the unified feed too, so the CLI and app agree.
  `--source` filters by any `ActivityKind` raw value (e.g. `created`, `recall`).

## Consequences

**Positive**
- Activity becomes a real activity log: a store/edit/delete shows up next to the
  recalls and searches, in one chronological stream.
- No schema change and no new write path — the `created` rows have been recorded
  all along; this only surfaces them. Idempotent, no migration.
- The read/write split stays honest: `accessed` is excluded, so ranking coupling
  (ADR 0005/0015) never leaks into the view, and reads aren't double-counted.

**Negative / trade-offs**
- Two enums now describe reads (`RetrievalSource` for recording, `ActivityKind` for
  display) with aligned raw values. Accepted: distinct roles, and the alignment is
  asserted by `ActivityKind(retrieval:)`.
- The timeline is busier — every `store` is a row. Bounded by the same lookback
  window and `limit` as before.
- A `deleted`-kind row points at a soft-deleted memory, so selecting it is inert in
  the inspector (consistent with the existing "gone memory" handling).
