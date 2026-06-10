---
name: queue
description: Capture a rough future-work idea, interpret it within Engram's current state, split it into one or more scoped tasks in the established `remaining-tasks.md` style, and append them. No commit. Activates when the user types `/queue <thought>`. Does NOT start the work.
argument-hint: <thought or paste of future-work idea>
allowed-tools: Read, Edit, Write, AskUserQuestion, Bash(git log:*)
---

# `/queue` — capture future work into `remaining-tasks.md`

The user has an idea and wants it captured for later. This skill turns it into properly-shaped task entries and appends them to `remaining-tasks.md`. No implementation happens here.

## What you must do

### 1. Read the project state

- `remaining-tasks.md` — the queue. Match its existing format.
- `CLAUDE.md` — operating rules, the ADR requirement, docs-in-sync rule.
- `Sources/`, `Engram/` — skim filenames to understand what's already built.
- `git log --oneline -10` — what shipped recently.

### 2. Interpret the idea

- **What does it touch?** `EngramCore` (store/embeddings/ranking)? the `engram` CLI? the Xcode app? hooks/skills? docs?
- **Is it one task or several?** One task ≤ ~200 lines net new code and ≤ ~4 files. Split if broader.
- **Is it architectural?** If it changes storage/sync strategy, the Claude Code integration model, the embedding backend, or module boundaries, it needs an **ADR** — queue the ADR as the first task in the sequence.
- **Does it conflict with scope?** No speculative abstractions beyond what the task needs.

### 3. Ask clarifying questions ONLY when genuinely ambiguous

Use `AskUserQuestion` only if you can't write a concrete acceptance criterion. Skip if the idea is precise.

### 4. Draft the task(s)

```
- **<Imperative title in one sentence>.** <Two-to-four sentences: what's changing, why, which files to read/modify. Be specific.>
  - Acceptance: <concrete, testable criteria — "make build && make test pass", "engram <cmd> behaves X", "ADR NNNN written and indexed". Avoid "looks good".>
```

Order tasks by dependency. Put any required ADR first.

### 5. Append to `remaining-tasks.md`

- Match the active section if the theme fits; add `## Phase N — <short theme>` if meaningfully different.
- If the file only has "No tasks queued", replace that note with a fresh section.
- Use `Edit` (or `Write` if rebuilding from empty) — never overwrite existing tasks.

### 6. Report and stop

Print: tasks queued (titles), section added to, any clarifications, and "work not started."

**Do not spawn an implementer. Do not write code. The skill ends here.**

## What you must NOT do

- Start coding or spawn implementer subagents.
- Bundle in unrelated edits.
- Reorder or rewrite existing tasks unless the user explicitly asks.
