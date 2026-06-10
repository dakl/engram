# 2. Keep documentation in sync with the code

- **Status:** Accepted
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring

## Context

Documentation drifts from reality unless it's updated alongside the change that
invalidates it. We've already hit this twice in early development: the README
described a per-turn recall hook after ADR 0001 superseded it, and the dev/prod
docs lingered after we collapsed to a single store. Stale docs actively mislead
— worse than no docs.

The project's docs surface includes: `README.md`, `CLAUDE.md`, the ADRs in
`docs/adr/`, `docs/ROADMAP.md`, and the Claude Code skill descriptions
(`~/.claude/skills/*/SKILL.md`) that document the CLI.

## Decision

**Documentation updates are part of "done", not a follow-up.** When a change
alters behavior, structure, commands, or a decision, update the relevant docs in
the same change:

- **README** — build steps, CLI usage, architecture overview.
- **CLAUDE.md** — layout, conventions, workflow rules.
- **ADRs** — when a decision changes, supersede with a new ADR; never silently
  rewrite an Accepted one. Update the index.
- **ROADMAP** — move items between Done / Planned as they ship or are added.
- **Skill descriptions** — when the CLI surface changes.

A change that needs an ADR (per `CLAUDE.md`) is not complete until that ADR is
written.

## Consequences

- Small, continuous overhead per change — paid where the context is freshest.
- Docs stay trustworthy, so they can be relied on (by humans and by Claude
  reading `CLAUDE.md`/skills) instead of re-derived from code each time.
- Review can include a "are the docs updated?" check.
