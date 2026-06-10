// Skill templates written by `engram setup`. Kept here as the source of truth
// so the bundled CLI can install the latest skills on demand.

let rememberSkill = """
---
name: remember
description: Save or update a durable memory in Engram. Use when the user asks to remember/save/note something, when you identify lasting information worth persisting (preferences, decisions, project facts, gotchas), or when you learn or summarize what a service/git repo does. Not for transient task details.
argument-hint: [what to remember]
allowed-tools: Bash
---

Store (or update) a memory in Engram via its CLI.

## Format

Memory content is **Markdown**. Always pass a concise one-line **`--title`** — the
display label shown in lists (ADR 0014); make it self-explanatory on its own
(e.g. `--title "studio-api purpose & stack"`). The content itself may still open
with a `# Heading`; when `--title` is omitted the list falls back to that first
line. For a service/repo note title use `<source> — <topic>`. Then the fact. Use
bullets or short sections when the content is naturally a list or has structure; a
sentence or two is fine otherwise. Keep it tight — markdown is for readability, not
bulk. Split a note that covers several distinct topics into one focused memory each
rather than one sprawling entry.

## What makes a good memory

Store **one durable fact per memory**, phrased so it's useful out of context months later. Good: "Daniel prefers uv over pip for Python." Bad: "we just ran the tests" (transient), or a whole paragraph (too broad to match).

Do **not** store: secrets/tokens, transient task state, or anything already obvious from the code/git history.

## Always summarize services / repos

Whenever the conversation establishes **what a service or git repo does**, store (or update) a memory summarizing it: its purpose, the language/stack, and any key responsibilities or boundaries. Tag it `type:fact,service` plus `language:<lang>`, set `--source` to the repo name, and give it `--title "<repo> — purpose & stack"`. Keep it to a couple of sentences.

## How to store a new memory

1. Distill the thing to remember into a concise fact (services: a couple of sentences), and write a one-line `--title`.
2. Set **faceted tags** (ADR 0013) — lowercase `key:value` tags the browser filters on:
   - `type:<kind>` — **always** add one: `decision`, `fact`, `preference`, `howto`, or `person` (others allowed).
   - `language:<lang>` — when the memory is language-specific (`python`, `swift`, `go`, …).
   - `project:<name>` — only for **additional** projects the memory relates to *beyond* the capture origin in `--source`; a memory may carry several.
   - Then 0–3 **freeform, lowercase, meaningful** tags for everything else. Don't repeat `--source` as a `project:` tag — it's folded in automatically.
3. **Always** set `--source` to the project the fact was captured in (usually the basename of the working directory), even for personal/non-code facts.

```bash
engram store "<the concise fact>" --title "<one-line label>" \\
  --tags type:<kind>,language:<lang>,<freeform> --source <project>
```

Verification flags (ADR 0008; inferred from tags/source if omitted, but **set them explicitly**):

- `--verifiability <class>` — one of `codeGrounded`, `configInfra`, `decision`, `projectState`, `userConfirmOnly`, `timeless`.
- `--check-anchor <path>` — **for any `codeGrounded`/`configInfra` fact, always pass a stable repo-relative file path** (or `branch:<name>`) whose presence confirms and whose absence refutes the memory (e.g. `go.mod`, a key package dir, a config file). Without an anchor, `/dream` can't cheaply verify the memory and it just rots. Pick something durable, not a line number.

## Updating an existing memory

If the new information **revises** something already stored (e.g. a repo's purpose changed), update it instead of adding a near-duplicate:

1. Find the existing memory and its id: `engram fetch "<topic>" --json` (or use `/recall`).
2. **Verify against reality before rewriting** — read the file/run the check; don't trust the old memory's claim, it may be stale.
3. Update by id:

```bash
engram update <uuid> --content "<revised fact>" [--title "<one-line label>"] [--tags <tags>] [--source <project>] \\
  [--verifiability <class>] [--check-anchor <path>]
```

`update` re-embeds the content and bumps the timestamp, so search and freshness stay correct. It also sets `--verifiability`/`--check-anchor` in place — use it to attach an anchor to an older memory that lacks one.

## Notes

- Writes go to the shared Engram store.
- Confirm briefly to the user what you stored or updated (one line). If asked to remember something with no content, ask what they want remembered.
"""
