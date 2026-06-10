---
name: work
description: Supervise Engram's work loop — read remaining-tasks.md (local, gitignored), confirm each task with the user before implementing, delegate to implementer + reviewer subagents, commit, remove the task, and repeat. Enforces the deslop checkpoint and CLAUDE.md/ADR self-reflection at the end.
argument-hint: <optional hint — e.g. "phase 1 only", "single task"; usually empty>
allowed-tools: Read, Edit, Write, Bash, Agent, AskUserQuestion
---

# `/work` — drive Engram's work loop end-to-end

The user wants the work in `remaining-tasks.md` executed. This skill orchestrates implementer + reviewer subagents through every queued task, **confirms each task with the user before any implementation**, commits each result, enforces the deslop checkpoint, and prompts CLAUDE.md/ADR self-reflection at the end. **You are the orchestrator, not the implementer.** Implementation happens in subagents.

## 0. Before you start

Read in this order:

- `git pull` (fast-forward only) — sync with remote. Surface conflicts and stop if any arise.
- `remaining-tasks.md` — the queue. If empty ("No tasks queued"), report and stop.
- `CLAUDE.md` (project) — the authoritative ruleset. Note the **ADR rule**: architectural changes (storage/sync strategy, the Claude Code integration model, embedding backend, module boundaries) MUST have an ADR in `docs/adr/` written *before* implementation. Docs stay in sync as part of every change (ADR 0002).
- `git log --oneline -10` — recent work + the deslop counter.
- `git status --short` — should be clean before starting. If modified tracked files are present and `make build && make test` pass on them, queue them as a task and process immediately rather than asking; if checks fail, surface the dirt and stop.

If the user's hint scopes the run (e.g. "phase 1 only", "single task"), narrow accordingly. If genuinely unclear, ask one targeted clarification before starting.

## 1. The loop, one iteration

For each iteration:

1. **Pick the next task from `remaining-tasks.md`:**
   - Read `remaining-tasks.md` (local, gitignored).
   - Pick the first unblocked task (skip any marked `[IN PROGRESS]`).

2. **Right-size.** If the task is > ~200 lines of net new code or touches more than ~4 files, plan a split. Splitting before delegating is non-negotiable — wide briefs fail more often.

3. **Plan.** Use Read/Bash to gather the files the task touches. Decide: exact files to modify, the approach in 1–3 lines, whether an ADR is required first, and the quality check that applies (`make build && make test`; add `make app` if the Xcode app changed).

4. **⛔ CONFIRMATION GATE — ask the user before implementing.** This is mandatory on every task. Present a tight summary:
   - Task title (verbatim).
   - Right-sizing decision (proceed as-is / split into N).
   - Exact files to be touched.
   - The 1–3 line approach.
   - ADR required? (yes + which / no).

   Then call `AskUserQuestion` with options:
   - **Proceed** — implement as described.
   - **Revise** — user adjusts scope/approach; re-present and ask again.
   - **Skip** — leave the task queued, move to the next one.
   - **Stop** — end the run.

   Do **not** spawn the implementer until the user picks Proceed. If they picked Proceed, append `[IN PROGRESS]` to the task line in `remaining-tasks.md` so concurrent sessions see the claim. If an ADR is required, write/update it first (delegate it like any other implementation, or — for a short ADR — confirm with the user whether the orchestrator may draft it), and get it committed before the code.

5. **Build the implementer brief.** Fetch every file the agent needs and compose a self-contained brief (≤800 words) with all context **inline** — don't rely on the agent to re-read from disk. Required ingredients:
   - The task text (verbatim) + acceptance criteria, restated.
   - Full contents of every file to modify or understand (pasted inline).
   - Quality check pasted verbatim: `make build && make test` — report PASS/FAIL. If no tests cover the touched module yet, note it. **If the task touches the Xcode app (`Engram/`), the agent MUST also run `make app` (programmatic `xcodebuild` of the macOS app) and report PASS/FAIL** — Xcode "Run" builds only the app, and `swift build` never compiles the app target, so this is the only check that the app actually builds.
   - Engram conventions (from CLAUDE.md): run `make test` after changing `EngramCore` or the CLI; `make install` to refresh the CLI; ADRs in `docs/adr/` for architectural changes; keep `README.md`, `CLAUDE.md`, ADRs + index, `docs/ROADMAP.md`, and skill descriptions in sync in the same change.
   - Style (from global + project rules): explicit variable names over abbreviations; comments only where logic is non-obvious; simple/readable over clever; match surrounding code.
   - "Implementer scope-creep budget is zero. No extra helpers, no bonus logging, no speculative abstractions. Only these files may be touched: <list each path explicitly>."
   - "Do not touch `remaining-tasks.md` — orchestrator handles task removal."
   - "Do NOT commit. Report under 150 words: files modified, `make build`/`make test` PASS/FAIL, judgment calls one line each."

   **Spawn the implementer** (`subagent_type: general-purpose`).

   **After the agent returns:** write its full response to `transcripts/<task-slug>-implementer-<timestamp>.md` (task-slug = first 5 words of the title, lowercase-hyphenated; timestamp = `date +%Y%m%d-%H%M%S`).

6. **Commit.** Once the implementer reports clean checks:
   - Run `git status --short` + `git diff --cached --stat` — inspect what actually changed. Verify only intended files are staged.
   - Stage only intended files: `git add <specific paths>`, never `git add .`.
   - Commit with a Conventional Commit message. The orchestrator owns committing.

7. **Delegate review.** Fetch the changed files and paste them inline. Spawn a *different* subagent with:
   - Task text + acceptance criteria (verbatim).
   - Commit hash + list of touched files.
   - Full contents of the changed files (`git show <hash> -- <file>` or Read).
   - Checks: acceptance met, no scope creep, explicit naming, comments only where non-obvious, ADR present if architectural, docs updated in sync, no regressions in existing `Sources/`/`Engram/` code, `make build && make test` clean (plus `make app` clean if the Xcode app was touched).
   - "Verify blockers before flagging — construct the concrete failure scenario. Don't fix phantoms."
   - Report shape: "VERDICT: APPROVE / APPROVE-WITH-NITS / REQUEST-CHANGES. Blockers as `file:line`. Nits optional."

   **After the reviewer returns:** write its full response to `transcripts/<task-slug>-reviewer-<timestamp>.md`.

8. **Address feedback.**
   - APPROVE: continue.
   - APPROVE-WITH-NITS: judge whether worth fixing; if yes, delegate the nit-fix to a subagent — the orchestrator does not edit source files.
   - REQUEST-CHANGES: send back to the implementer with a tight "what to fix and why". Re-review only if changes are non-trivial.
   - Cross-check reviewer claims against the diff before acting. Downgrade non-reproducible "bugs".

9. **Remove the task from `remaining-tasks.md`** (no commit — it's gitignored). Delete the entry and any `[IN PROGRESS]` marker.

10. **Verify.** `make build && make test` must be clean. If the task touched the Xcode app (`Engram/`), `make app` must also build clean. Fix forward if they fail — do not revert.

11. **Loop.** Return to step 1 (which re-enters the confirmation gate for the next task).

## 2. Parallelism

When two tasks are disjoint (don't share files), you may spawn both implementers in parallel with `isolation: "worktree"` — but only after **each** has passed its own confirmation gate. Sequential is the default; parallel is the optimization. Merge sequentially; reviewers can fan out. Verify worktree isolation before cherry-picking: if the commit is already on the orchestrator's branch, skip the cherry-pick. Don't poll background agents — the harness notifies on completion.

## 3. The deslop checkpoint

Match the conventional-commit *subject*:

```sh
LAST=$(git log --extended-regexp --grep='^(refactor|fix|chore|feat)\(deslop\)' -1 --format=%H)
git rev-list --count $LAST..HEAD --no-merges
```

If count ≥ 10, run the deslop pass (`.claude/skills/deslop/SKILL.md`) before the next implementer.

## 4. CLAUDE.md / ADR self-reflection (end of run)

Before terminating, invoke `.claude/skills/self-reflection/SKILL.md`. Null reflections are valid — don't fabricate.

## 5. Final report

- Iterations completed (commit hashes + one-line summaries).
- Tasks skipped or stopped at, and why.
- Deslop passes run (count + hashes).
- Self-reflection outcome (hash or "no changes warranted").
- Anything uncommitted, broken, or weird.
- "Queue is empty" OR "Stopped early because <reason>".

## What you must NOT do

- **Implement work yourself.** Allowed orchestrator actions: reading state, spawning agents, mechanical git operations, `remaining-tasks.md` edits, rescuing uncommitted diffs to `/tmp`. Everything else: subagent.
- **Skip the confirmation gate.** Every task is confirmed with the user before implementation — that is the point of this skill.
- **Skip the reviewer step.** Every task gets a reviewer.
- **Let a subagent commit.** The orchestrator owns all git commits.
- **Implement an architectural change without its ADR landing first.**
- **Use destructive git commands** (`--force`, `reset --hard`, `branch -D`) without explicit user confirmation.
- **Poll background agents.**
- **Bundle unrelated edits into a task's commit.** `git add <specific paths>`, not `git add .`.
- **Feed a subagent only file paths.** Paste actual file contents inline — the brief must be self-contained.
- **Leave stale `[IN PROGRESS]` markers** in `remaining-tasks.md`.
