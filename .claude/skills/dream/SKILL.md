---
name: dream
description: Scheduled memory maintenance for Engram — verify the highest rot-risk memories, confirm the ones that still hold, and supersede the ones reality has moved past. Maintenance only; never summarizes or merges memories. Runs safely as a dry-run by default; pass `--apply` to write changes. Intended to run nightly via /schedule.
argument-hint: [--apply] [--limit N]
allowed-tools: Bash, Task, Read
---

Maintain the Engram memory store: surface and fix rot, without ever
summarizing or clustering memories (that is what slopped the prior system —
see ADR 0008). **Default is a dry-run** that mutates nothing and just reports;
only `--apply` writes changes.

## 1. Pull the riskiest candidates
```bash
engram list --by-risk --limit ${LIMIT:-20} --json
```
Rot-risk already excludes `userConfirmOnly`/`timeless` (they score 0), so you
only see machine-checkable memories.

## 2. Deterministic verdicts first (cheap, no LLM)
```bash
engram verify --json
```
Match verdicts to the candidates by `id`. Verdicts: `confirmed | contradicted | stale | inconclusive`.

## 3. Act on each candidate
- **confirmed** → it still holds. In `--apply` mode: `engram verified <id>` (bumps `verified_at`, lowers its future risk).
- **contradicted** (e.g. the `checkAnchor` file is gone) → reality moved.
  - If you can determine the corrected fact from the repo, in `--apply` mode supersede it:
    `engram supersede <id> "<corrected markdown fact>" --reason "<what changed>" --tags <tags> --source <repo>`.
  - **High-certainty contradiction with no replacement** — the `checkAnchor` is gone AND the thing the memory describes no longer exists, so there's nothing to supersede it *with*: in `--apply` mode soft-delete it with `engram delete <id>`. This is the ONLY case `/dream` deletes, and `delete` is a recoverable tombstone (the row is kept), so it's safe. If you're unsure whether a replacement exists → do NOT delete; digest it.
  - Otherwise (fix unclear) → add to the **review digest** (don't guess).
- **stale** (old `as of <date>`) → treat like contradicted: supersede if you can refresh it, else digest it.
- **inconclusive** → escalate to a subagent (see §4) only if it has a `checkAnchor`; otherwise leave it and digest it.

## 4. Escalate `inconclusive` by FALSIFICATION
For each inconclusive memory **with a `checkAnchor`**, spawn a subagent (Task)
whose job is to **disprove** the memory — not confirm it. Give it the memory
content + `checkAnchor` + its `source` repo, and instruct: "Find concrete
evidence this is now FALSE (run the checkAnchor grep/command, read the file).
Report DISPROVED + the corrected fact, CONFIRMED + the evidence, or UNKNOWN."
- DISPROVED → (`--apply`) `engram supersede` with the corrected fact.
- CONFIRMED → (`--apply`) `engram verified <id>`.
- UNKNOWN → leave it; add to the digest.

A falsification prompt resists the rubber-stamping a "prove it's still true"
prompt invites.

## 5. Report a digest
Always end with a digest (printed, never stored as a memory):
- confirmed/re-verified: N
- superseded: N (old → new, with reason)
- soft-deleted (high-certainty contradiction, recoverable): N
- **needs your review** — for each memory that couldn't be auto-resolved, show its
  verdict + why and offer the three actions: **keep** (it's still fine — I'll
  `engram verified` it), **update** (give me the new fact — I'll `engram supersede`),
  or **drop** (`engram delete`, recoverable). Nothing in this list is touched
  until you choose.

In dry-run (the default) the digest describes what *would* happen; nothing is
written. Tell the user to re-run with `--apply` to enact it.

## Hard rules
- **Maintenance only.** Never rewrite a memory into a summary, never merge or
  cluster memories. The only writes are `engram verified` and `engram supersede`.
- **Supersede, don't delete.** History is preserved via `superseded_by` + `evolution_reason`.
- Operate on the shared store (no `--env`).

## Scheduling
Run nightly via `/schedule` (e.g. a routine that invokes `/dream --apply` at a
quiet hour). Start with dry-run runs until you trust its supersede decisions.
