# 15. Retrieval activity tracking: a dedicated, ranking-decoupled ledger

- **Status:** Accepted
- **Date:** 2026-06-04
- **Deciders:** Daniel Klevebring
- **Relates to:** ADR 0005 (gated per-request recall) — this does **not**
  supersede it; it deliberately preserves its loop-break.

## Context

We want to gauge **how much each memory is actually used** — a lookback view
(`15m` / `1h` / `6h` / `1d`) listing which memories were retrieved in a window,
with timestamps, plus a matching CLI command.

The data doesn't exist today. The dominant retrieval paths record nothing:

- The auto-recall hook calls `fetch(…, recordAccess: false)` **on purpose**
  (ADR 0005): recording access there bumped `access_count`, which feeds
  `Ranking`, creating a rich-get-richer feedback loop (a noise memory hit
  `access_count = 15` from test queries alone). The app search box does the
  same.
- The existing `events` table logs only lifecycle
  (`created`/`accessed`/`updated`/`deleted`). Its `accessed` kind fires only on
  *deliberate* `fetch`/search **and is entangled with ranking** — so it is both
  sparse and unsuitable as a usage signal.

There are five distinguishable retrieval modes, three of them hooks:

| source | trigger | has a query? |
|---|---|---|
| `recall` | `UserPromptSubmit` hook — query-driven auto-recall | the prompt |
| `session-digest` | `SessionStart` hook — project-scoped recents | — |
| `verify-context` | `SessionStart` hook — checks code-grounded memories | — |
| `fetch` | explicit `engram fetch` | the query |
| `search` | app search box (reserved) | the query |

## Decision

- **A dedicated `retrievals` table**, separate from `events`:
  `(id, memory_id, source, query, at)`, indexed on `at`. One row per memory per
  retrieval. No foreign key to `memories` (matching `events`), so a deleted
  memory's history survives for analytics; readers join and tolerate misses.
- **Fully decoupled from `access_count`/`Ranking`.** `recordRetrieval` only
  writes this ledger — it never bumps `access_count` — so ADR 0005's loop-break
  holds by construction. `accessed` lifecycle events and their ranking coupling
  are left exactly as they are.
- **Record what each hook actually surfaces into context** — recall→the gated
  `confident` set, session-digest→the `top` listed, verify-context→the
  `flagged` (stale/contradicted) shown. This gives one uniform "shown to
  Claude" definition across modes. `fetch` records its returned results. The
  `search` source is **reserved, not emitted automatically**: the app's search
  is intentionally read-only (it must not write to the store file, which would
  trip the change-watcher and flood the ledger on every keystroke).
- **The `source` is stored per row** so the timeline and any analytics can
  filter or break down by mode.
- **The query/prompt is stored when available**, truncated to 500 chars.
- Surfaced through **`engram activity --since <dur> [--source S] [--json]`** and
  a new top-level **Activity** view in the app.

## Consequences

**Positive**
- Usage becomes measurable per memory and per mode, without re-entangling
  retrieval with ranking.
- One additive table; idempotent `CREATE TABLE IF NOT EXISTS`, no migration shim.
- Recording is wrapped in `try?` at every hook call site, so analytics can never
  block a session or prompt.

**Negative / trade-offs**
- Stores prompt text locally. Acceptable for a local-only, single-user,
  non-sandboxed store (ADR 0003); bounded by the 500-char truncation.
- "Surfaced" ≠ "used": the ledger records that a memory was shown to Claude, not
  that Claude relied on it (unknowable). The timeline measures exposure, the
  honest signal we can capture.
- `recall` runs on every prompt, so the table grows roughly with prompt volume.
  Pruning/retention can be added later if it matters; rows are tiny.
