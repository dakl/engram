# 13. Faceted tags: reserved `key:value` convention over flat tags

- **Status:** Accepted
- **Date:** 2026-06-04
- **Deciders:** Daniel Klevebring

## Context

Memory discovery underdelivers (see `docs/discovery-memory-exploration.md`). One
root cause: **flat, freeform tags** give nothing clean to group or filter by. A
faceted browser — "show me `type:decision` in `project:engram`" — needs structure
the current tag set lacks.

Competitive research (Obsidian inline fields, Logseq `key:: value`, Tana fields,
Capacities properties) converges on the same lesson for a personal-scale store:

- **`key:value` faceting scales down cleanly**; a faceted filter bar covers nearly
  every need without a query DSL (Dataview/Datalog is overkill at hundreds–thousands
  of items).
- **Typing must be opt-in, not mandatory on capture.** The apps that force a type
  on every item (Tana/Capacities) impose friction; the successful middle path keeps
  capture freeform and layers structure only where it pays (Heptabase, Obsidian).

Today tags are stored flat in `memory_tags(memory_id, tag)` and indexed in FTS via
`group_concat`. The current `/remember` skill **actively forbids** prefixed tags
("`topic:`, `project:` … are noise"). This ADR reverses that guidance.

## Decision

Introduce **faceted tags as a reserved `key:value` convention layered on the
existing flat tag set** — facets *are* tags, distinguished only by a `:`.

### 1. Reserved facet keys
Three reserved keys, parsed into a faceted filter bar:

| Key | Meaning | Recommended (open) vocabulary |
|-----|---------|-------------------------------|
| `type` | what kind of memory | `decision`, `fact`, `preference`, `howto`, `person` |
| `project` | which project/repo | free (matches a `source`) |
| `language` | primary language | `python`, `swift`, `go`, … |

Vocabularies are **recommended, not enforced** — `type:experiment` is allowed.
Any other `key:value` tag is tolerated and shown as a generic facet; bare tags
(no `:`) remain freeform.

### 2. `project` is a multi-valued facet, distinct from `source`
A memory can relate to **several** projects, so `project` cannot simply mirror the
single-valued `source` column. The two are distinct concepts, not duplication:

- `source` stays the **capture origin** — one repo, set via `--source`, used by the
  verification hook (ADR 0008).
- `project:` facet-tags express **relatedness** — zero or more projects a memory
  pertains to.

All three reserved facets (`type`, `project`, `language`) are therefore authored as
`key:value` tags. The facet rail's `project` filter **unions** a memory's `project:`
tags with its `source` (the capture origin counts as an implicit project membership),
so a memory always appears under the project it came from even before extra
`project:` tags are added.

### 3. No DB migration for the core feature
Facets are tags + a pure-code parser + filter logic + UI. The `memory_tags`
schema, FTS indexing, and store API are unchanged. `normalize()` must **preserve
the `:`** (lowercasing values is fine: `type:Decision` → `type:decision`).

### 4. Enrichment backfill is optional and deferred
Assigning `type:`/`language:`/extra `project:` tags to the existing ~hundreds of
memories is **lossy inference**, not a mechanical migration — it belongs to a
separate `/dream`-style LLM pass and is **not required for this feature to ship**.
The one cheap, deterministic seed: each memory's `source` already implies its
originating `project` (handled by the union in §2), so existing memories are
project-filterable from day one. New memories get full facets from `/remember`;
old ones gain `type:`/`language:` lazily.

### 5. `/remember` skill update
Reverse the "no prefixes" rule: instruct the model to add `type:` (always),
`language:` (when a memory is language-specific), and `project:` for **additional**
related projects beyond the capture origin (which stays in `--source`); use
freeform tags for everything else.

## Consequences

**Positive**
- A faceted filter bar becomes possible with the smallest blast radius — no schema
  migration, no data rewrite.
- Opt-in `key:value` matches the proven personal-scale pattern; freeform tags survive.
- Facet tokens (`type:decision` → `type`, `decision`) improve FTS recall for free.

**Negative / trade-offs**
- A convention, not a constraint: nothing stops malformed or inconsistent facets;
  the UI must tolerate them gracefully.
- Existing memories look facet-poor until the optional enrichment pass runs.
- Reverses prior skill guidance — older stored memories won't match the new
  convention until re-touched.

## Related
Feeds the faceted-list home view (the primary discovery surface). Complements
ADR 0008 (`source`-keyed verification) and precedes the display-title work
(ADR 0014) and the derived entity/relation index (revives ADR 0007).
