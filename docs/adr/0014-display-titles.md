# 14. Authored display titles, model-written at store time

- **Status:** Accepted
- **Date:** 2026-06-04
- **Deciders:** Daniel Klevebring

## Context

Across the memory systems surveyed (`docs/discovery-memory-exploration.md`),
**titling is the universal weak spot.** Document-centric stores (mem0, doobidoo,
Supermemory) render raw content or auto-summaries in lists, and they read poorly.
The systems that read well (basic-memory, Capacities, the canonical MCP KG) got
there because a human or an extraction step **named the unit**.

Engram today has no display title. Lists render the memory's first line. The
`/remember` convention already asks the model to start content with a `# Title`
line, but that title is buried in the markdown blob, isn't a first-class field,
and isn't editable independently of the content.

A scannable list — one clean line per memory — is what makes a faceted home view
work. An authored title decouples "what's shown" from the full content.

## Decision

Add an optional **`title`** field, **model-written at store time**, editable later.

### 1. Schema
Add a nullable `title TEXT` column to `memories`, via the existing additive
`ALTER TABLE ADD COLUMN` migration path (the `requiredColumns` list). No
destructive change; older rows have `title = NULL`.

### 2. Authoring
`/remember` writes a concise one-line `title` when storing a memory, so **new
memories read well instantly**. The CLI `store`/`update` commands gain a
`--title` flag; the store API gains a `title` parameter.

### 3. Display fallback
When `title` is `NULL`, the UI falls back to today's behaviour (first line /
truncated content). This keeps the feature additive and the app correct before
any backfill.

### 4. Backfill
A **one-time pass** assigns titles to the existing ~hundreds of memories
(deriving from the existing `# Title` first line where present, summarizing
otherwise). Deferred and non-blocking — the fallback covers untitled rows.

### 5. Editable
The app detail view exposes the title as an inline-editable field. Editing the
title never touches `content`; the two are independent.

## Consequences

**Positive**
- Lists become scannable — the single highest-ROI fix the research identified.
- New memories read like a human named them, with zero added user effort.
- Additive and reversible: a nullable column with a safe fallback.

**Negative / trade-offs**
- A schema migration (one nullable column) and a `/remember` + CLI surface change.
- Titles can drift from content if edited independently — accepted; the title is
  a display label, not a source of truth.
- Existing memories show fallback titles until the backfill pass runs.

## Related
Pairs with ADR 0013 (faceted tags) to make the faceted-list home view scannable
and filterable. The backfill pass shares machinery with the `/dream` flow
(ADR 0008) and the future derived index (revives ADR 0007).
