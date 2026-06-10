---
name: deslop
description: Run a metric-driven Swift quality pass — measure with `make metrics` (lizard cyclomatic complexity + function length, swiftlint if present) into metrics/quality.json, pick the top offenders, refactor under green `make build && make test` with no behaviour change, and re-run metrics to verify every change actually improved. Activates when the user types `/deslop`, when `/work` hits the deslop checkpoint, or when code feels crusty.
argument-hint: --target <code|tests> [--iterations N]   (or just a free hint)
allowed-tools: Read, Edit, Write, Bash, Agent
---

# `/deslop` — metric-driven quality-drift sweep (Swift)

Quality drift compounds quietly. When the trigger fires, the next implementer waits and this runs first. Every change must be **verified against metrics** — not vibes.

## 0. When to run

- **Counter tripped** — ≥10 substantive commits since the last deslop pass:
  ```sh
  LAST=$(git log --extended-regexp --grep='^(refactor|fix|chore|feat)\(deslop\)' -1 --format=%H)
  git rev-list --count $LAST..HEAD --no-merges
  ```
- **User asks** — `/deslop` typed directly, or "feels crusty".
- **End of a long `/work` run.**

## Arguments

- `--target code` — only modify production code (`Sources/`, `Engram/Engram/`). **Default.**
- `--target tests` — only modify test files (`Tests/`, `Engram/EngramTests/`, `Engram/EngramUITests/`).
- `--iterations N` — make N successful improvements before stopping. Default: 3.

Never touch files outside the target group.

## 1. Baseline

```sh
make metrics      # → metrics/quality.json
make build && make test   # must be green before you start
```

Read `metrics/quality.json` and store the baseline. Print a one-line summary: code file count, total lines, mean/max complexity, top hotspot. If `make build`/`make test` is red at baseline, stop — fix or report; never deslop on a broken tree.

## 2. Identify offenders (orchestrator picks — this is judgment, don't delegate it)

From `metrics/quality.json`, for the selected target only, pick the highest-leverage issues in this priority order:

1. `hotspots.by_complexity` with `ccn > 4` — multiple branching paths; split or simplify.
2. `hotspots.by_length` with `length > 20` — functions doing several things; split by responsibility.
3. Lint violations (if `swiftlint` present) — tackle the most frequent rule first. Fix the code, never suppress.
4. Entries in `DESLOP_HINTS.md` (repo root, if present) — each line is a named refactor target; take the first uncompleted one.
5. Comment ratio outliers — `< 2%` (underdocumented non-obvious logic) or `> 30%` (over-commented obvious code).

Pick the worst 3–5 (or up to `--iterations`). Read the full file before changing anything.

## 3. Refactor under green checks (delegate fixes to a subagent)

No behaviour change. Allowed refactors: extract private helpers; replace nested conditionals with guard/early-return; rename unclear identifiers to be explicit; remove redundant comments / add comments only where logic is non-obvious; fix lint by correcting code.

**Hard rules:**
- Never change observable behaviour — refactor only.
- Never add or remove public API surface.
- Only touch files in the target group.
- One logical change at a time, not a sweeping rewrite.

Delegate to a `general-purpose` subagent with a brief that pastes the offender file(s) inline and states: "No behaviour change. `make build && make test` must stay green. Touch only <paths>. Scope-creep budget is zero." A bug uncovered during the pass gets its own implementer brief (commit `fix(deslop): ...`).

## 4. Verify each change against metrics

After each change: `make build && make test` (must stay green), then `make metrics` and re-read `quality.json`.
- Improved or held: count it as a successful iteration. Print `✓ <what changed> — <metric> before → after`.
- Got worse: revert with `git checkout -- <path>`, note the failed attempt, pick the next candidate. Do not count it.

### Stopping conditions (stop without asking)
- The requested number of successful iterations is complete.
- No priority 1–3 candidates remain that haven't already failed this run.
- Every remaining candidate would require touching a known false positive (see Codebase notes).

## 5. Commit

Conventional commit subject **must** match the deslop-counter grep:
- `refactor(deslop): ...` / `fix(deslop): ...` / `chore(deslop): ...`

Body:
- One line per metric moved (e.g. `complexity max 10→7; MemoryStore.update split`).
- Offenders fixed (`file:function`).
- Accepted offenders + reasoning.

Stage by path (`git add <paths>`), never `git add .`. After committing, run `make build && make test && make metrics` once more — all green, metrics written.

## What you must NOT do

- **Behaviour change in a deslop pass.** Queue it via `/queue`.
- **Fix every finding.** Pick 3–5 / `--iterations`.
- **Trust a refactor you didn't re-measure.** Every change is verified against `quality.json`.
- **Suppress lint** instead of fixing the code.
- **Use `git add .`** — stage by path.
- **Skip the commit body** — future passes rely on it to reconstruct accepted offenders.
- **Run deslop mid-task.** Finish the current task first.
- **Delegate offender selection.** Picking is judgment (orchestrator); fixing is delegated.

## Codebase notes (Swift / SwiftUI refactoring-safety; carried from handla-app)

These are lizard/SwiftUI artefacts — verify before acting on a hotspot:

<!-- learned --> Adding a helper only improves the distribution when the code it replaces is already lizard-tracked (inside a named `func`, not a SwiftUI `body` property, `@ViewBuilder` closure, or `.alert`/`.sheet` content). Adding a helper to simplify *untracked* SwiftUI modifier content adds a function without removing tracked lines → metrics regress. Verify call sites are in tracked functions first.

<!-- learned --> `@ViewBuilder` computed properties score high `ccn` from `if/else` that is purely declarative layout — do not extract; the branches express view structure, not logic. Named `@ViewBuilder func` methods (parameter-taking) are different: extraction IS safe and reduces tracked length.

<!-- learned --> `@Bindable var model` and `private(set)`/`@Observable` cause lizard to emit a phantom `set` entry with inflated ccn/length that maps to no real function — skip it; look at the real `init`/body.

<!-- learned --> lizard can fuse consecutive `async func` declarations, attributing the second's lines to the first. Before acting on a suspicious `by_length` hotspot, count the actual lines in the file.

<!-- learned --> `make test` (SwiftPM) does NOT compile the Xcode app target under `Engram/Engram/` — only `Sources/`+`Tests/`. So a refactor of an app-only function (e.g. `EngramModel.runBundledEngram`) can't be verified by `make build && make test`; it needs `make app` (xcodebuild, slow). Prefer `Sources/` hotspots; defer app-target hotspots unless you budget an app build to verify them.

<!-- learned --> Tests use swift-testing (`@Test` macros), so `swift test`/`make test` prints a spurious `Executed 0 tests` line from the empty XCTest harness. Trust the swift-testing summary (`Test run with N tests ... passed`) instead — `Executed 0` does not mean tests failed to run.
