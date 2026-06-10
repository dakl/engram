---
name: self-reflection
description: Reflect on `CLAUDE.md` and the skill files under `.claude/skills/` after a working session — surface rules that helped, rules that produced friction, rules that were skipped, and stale references. Edit the ruleset directly; commit as `docs(claude): self-reflection ...`. Activates when the user types `/self-reflection` or `/reflect`, when `/work` terminates, or whenever a rule feels wrong mid-session.
argument-hint: <optional hint — e.g. "just the work skill"; usually empty>
allowed-tools: Read, Edit, Write, Bash
---

# `/self-reflection` — keep the ruleset current

`CLAUDE.md` and the skill files under `.claude/skills/` are living documents. Stale rules and silently-skipped rules degrade them. This skill walks the ruleset and updates it based on what was just observed.

## 0. When to run

- At the end of a `/work` run (the work skill invokes this).
- After a session where a rule felt wrong — capture immediately.
- After a change that may have invalidated rule references (a renamed module, a new ADR, a changed CLI surface).
- On user demand via `/self-reflection` or `/reflect`.

If the session had no friction and no stale references, write nothing. A null reflection is valid.

## 1. Read the surface

- `CLAUDE.md` (project) — the authoritative ruleset.
- `.claude/skills/work/SKILL.md`, `deslop/SKILL.md`, `queue/SKILL.md` — skill rules.
- `git log --oneline -20` — what just happened.

Narrow to the user's hint if provided.

## 2. Ask of each rule

- **Did it actively help?** Keep it.
- **Did it get in the way?** Fix the rule or document the exception + when to apply it.
- **Was it skipped?** Why? Add a clearer threshold/trigger, or delete it.
- **Is anything stale?** File paths, module names, CLI subcommands, ADR numbers, commit IDs, references that no longer exist. Update or delete.
- **Did a new pattern appear?** Write the rule now. Be specific — name the file, the failure mode, the recurring brief instruction.

## 3. Edit

Edit `CLAUDE.md` and skill files directly. Same-session edits — future sessions won't have your in-memory exception list.

- **Tighten, don't expand.** One sentence beats a paragraph.
- **Link, don't duplicate.** If a rule lives in another file, link to it.
- **Don't fabricate observations.** If a rule wasn't tested this session, don't touch it.
- **Architectural learnings go in an ADR**, not just CLAUDE.md, when they change a decision.

## 4. Commit

```
docs(claude): self-reflection after <what just happened>
```

Body: substantive changes, one line each. Inspect `git diff --cached --stat` — reflection commits should only touch `CLAUDE.md` and `.claude/skills/**` (and an ADR if a decision changed).

If no edits are warranted, skip the commit and say "no changes warranted."

## What you must NOT do

- **Fabricate edits to look productive.** Null reflection is valid.
- **Rewrite a rule just because you didn't like the phrasing.**
- **Auto-fix mid-task.** Save reflection for a natural pause.
- **Reflect on rules that aren't yet tested.**
- **Bundle unrelated edits.** Reflection commits touch only the ruleset (+ ADR if warranted).
- **Delete a rule because it was inconvenient once.** One data point isn't enough.
