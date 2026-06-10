# 3. Mac app distribution: non-sandboxed dev-tool that ships and installs the CLI, hooks, and skills

- **Status:** Accepted
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring
- **Supersedes:** the earlier (un-ADR'd) choice to keep the macOS app sandboxed
  with an App Group.

## Context

Engram's macOS app is evolving into a **hub for the Claude Code integration**:
it ships the `engram` CLI and offers one-click buttons to install the CLI (to a
PATH dir), the recall hook (to `~/.claude/settings.json`), and the `/remember`
and `/recall` skills (to `~/.claude/skills/`).

Every one of those writes **outside an app sandbox container**. The App Sandbox
categorically forbids this — which is why comparable developer tools (VS Code's
`code`, Sublime's `subl`, Claude Desktop) are not sandboxed. The original
sandbox choice was made for a hypothetical App-Store iOS companion, before the
installer direction existed.

## Decision

**The macOS app is not sandboxed.** It is distributed directly (Developer ID +
notarization + hardened runtime), not via the Mac App Store.

- `ENABLE_APP_SANDBOX = NO`; the entitlements file drops `app-sandbox` and
  `application-groups`.
- **Install logic lives in the CLI**, the single source of truth:
  - `engram install` — copies the running binary to `/usr/local/bin/engram`.
  - `engram setup` — merges the `SessionStart` recall hook into
    `~/.claude/settings.json` (idempotent, backs up first) and writes the
    `/remember` + `/recall` skills from templates embedded in the binary.
- The app **bundles the freshly-built CLI** at `Contents/Helpers/engram` (a
  build phase compiles it on every build, so "update app → install latest"
  holds) and its toolbar buttons simply shell out to the bundled
  `engram install` / `setup`. It must be `Helpers/`, not `MacOS/`: the CLI
  `engram` would collide with the app binary `Engram` on case-insensitive APFS
  and clobber it.
- The **store moves to `~/Library/Application Support/Engram/engram.sqlite`**.
  A non-sandboxed app reading the old `~/Library/Group Containers/…` path
  triggers a macOS "access data from other apps" privacy prompt, since Group
  Containers is sandbox-owned. Existing data was migrated; the old file is kept
  as a backup.
- A future **iOS companion is a separate target** and can be sandboxed /
  App-Store-distributed on its own.

## Consequences

**Positive**
- The installer buttons work as intended; one place (the CLI) owns install logic.
- Standard, well-understood distribution model for a developer tool.

**Negative / trade-offs**
- The macOS app cannot ship on the Mac App Store (acceptable — its job is to
  manage local developer tooling).
- We rely on Developer ID notarization + hardened runtime for trust instead of
  the sandbox. Bundled binaries must be signed with the hardened runtime.
- Writing to `/usr/local/bin` may require it to be user-writable (it is on this
  machine); otherwise the CLI install needs an elevation path (future work).
