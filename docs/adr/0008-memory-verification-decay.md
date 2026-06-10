# 8. Memory verification & decay subsystem (the `/dream` design)

- **Status:** Accepted
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring

## Context

Memories rot. Code changes, branches merge, configs move, decisions get
superseded — and a stored fact that was true last month silently misleads
today. We want freshness *without* the failure mode of the prior system
(doobidoo), whose auto-capture + lossy "Cluster of N memories…" summarization
produced most of its slop.

Two observations shape the design:

- **Memories differ in how (and whether) they can be checked.** "The billing
  service is written in Go" is checkable against a repo; "Daniel prefers uv over
  pip" is a preference only the user can confirm.
- **Cheap signals catch most rot.** A referenced file that no longer exists, a
  merged-and-deleted branch, or an "as of <date>" past its shelf life are
  deterministic — no LLM needed.

## Decision

A maintenance subsystem that **verifies and supersedes**, never summarizes.

### 1. Verifiability classes
Each memory carries a `verifiability`:

| Class | Meaning | Auto-verified? |
|-------|---------|----------------|
| `codeGrounded` | claims about code | yes — against the repo |
| `configInfra` | infra/config facts (paths, services, GCP projects) | yes |
| `decision` | a decision/rationale; stale only if superseded | lightly |
| `projectState` | transient status ("PR open", "next step") | yes — ages fast |
| `userConfirmOnly` | preferences/opinions only the user can confirm | **no** |
| `timeless` | durable facts unlikely to change | **no** (≈0 risk) |

### 2. `checkAnchor`
An optional machine-checkable anchor — a file path, grep, command, or query —
that **confirms or refutes** the memory. Its quality determines verification
power; memories without one fall back to age/conflict heuristics.

### 3. Rot-risk score
`risk = time_since_verified × volatility(class) × verifiable? × importance(access_count)`.
`userConfirmOnly` and `timeless` score ≈ 0 and are excluded from
auto-verification. Risk decides *what to check first*.

### 4. Two triggers
- **Contextual hook (cheap, high-signal):** when working in repo X, verify 1–2
  of X's `codeGrounded` memories against the already-loaded repo — free context,
  no extra fetch. Always exits 0; never blocks a session.
- **Scheduled `/dream` (the tail):** periodically pull top-N by risk and verify.

### 5. Verification by falsification, deterministic pre-checks first
- **Deterministic checks first** (no LLM): referenced file missing →
  `contradicted`; git branch/PR gone or merged-and-deleted → `stale`;
  `"as of <date>"`/TODO past a threshold → age-flag; high embedding similarity +
  contradictory content → conflict pair. Verdict per memory:
  `confirmed | contradicted | stale | inconclusive`.
- **Deterministic `verify` scope:** file-existence, git-branch liveness
  (`branch:<name>` anchor — present → `confirmed`, gone → `stale`), and age.
  PR-liveness (needs a network call) and conflict-pair detection (needs an LLM)
  are deliberately excluded; conflict-pairs are handled by the `/dream`
  falsification escalation below.
- **Only `inconclusive` escalates** to an LLM subagent, prompted to *disprove*
  the memory using its `checkAnchor`. Falsification, not confirmation — a
  "prove it's still true" prompt rubber-stamps; "find evidence it's wrong" does not.

### 6. Supersede, never silently delete
- Confirmed-stale-with-replacement → **supersede**: a new memory linked via
  `supersededBy` + `evolutionReason`, preserving history.
- **Auto-delete only** on high-certainty deterministic contradiction (referenced
  file gone, no replacement).
- Everything ambiguous → a **user review digest** (keep / update / drop).

### 7. Maintenance only — no summarization
`/dream` verifies and supersedes. It **never** rewrites, merges, or clusters
memories into lossy summaries — that is precisely what slopped the prior system.

## Consequences

**Positive**
- Memories stay trustworthy; deterministic checks catch most rot for free.
- Falsification framing resists LLM over-confirmation.
- Supersede-not-delete preserves history and will feed ADR 0007's deferred
  explicit `supersedes`/`contradicts` graph edges.

**Negative / trade-offs**
- New schema fields + a migration (Phase 1).
- The `/dream` LLM tail costs tokens — bounded by risk-ranking and by escalating
  only `inconclusive` memories.
- Verification power is only as good as each memory's `checkAnchor`.

## Build order
Phase 1 (data model) → 2 (deterministic checks) → 5 (contextual hook) →
3 (risk score) → 4 (`/dream`) → 6 (review flow). Phases 2 + 5 deliver most of
the value before any scheduled LLM verification.

## Related
Complements ADR 0001 (store/recall) and ADR 0007 (graph). Distinct from the
graph work: this keeps memories *true*; the graph makes their relationships
*visible*.
