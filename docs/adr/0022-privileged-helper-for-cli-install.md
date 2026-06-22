# 22. Privileged helper (SMAppService + XPC) for installing the CLI symlink

- **Status:** Accepted
- **Date:** 2026-06-22
- **Deciders:** Daniel Klevebring, Claude
- **Relates to:** ADR 0003 (non-sandboxed dev-tool app), issue #4

## Context

The app's "Install the engram CLI" button calls `Setup.installCLI()`, which
writes `/usr/local/bin/engram`. `/usr/local/bin` is on `/etc/paths` on every
macOS machine, so it's the correct install target — but it is only
user-writable on Intel Macs where Homebrew has `chown`ed `/usr/local` to the
user. On Apple Silicon (Homebrew lives in `/opt/homebrew`) and on fresh macOS
installs, `/usr/local` stays root-owned and the write fails with
`NSCocoaErrorDomain 513` / `EACCES`. `~/.local/bin` is not a viable fallback —
it isn't on the default `$PATH`, so the installed hooks (which reference the
absolute binary path) would silently break.

A first, short-term mitigation (issue #4 "short-term fix", separate change)
switched the copy to a symlink — fixing post-update version drift — and
surfaced a clear "run `sudo engram install` in Terminal" message when the write
is denied. That keeps the failure legible but still drops the user to a
terminal; the button does not actually install.

For a one-click install with no Terminal, the app must perform the write with
elevated privileges. The supported post-macOS-13 mechanism is a
`SMAppService`-registered **LaunchDaemon** that the app drives over **XPC**;
the deprecated `AuthorizationExecuteWithPrivileges` and the older
`SMJobBless` flow are explicitly avoided.

## Decision

Add a privileged helper that creates the `/usr/local/bin/engram` symlink as
root, reached from the app over XPC and registered with `SMAppService`.

1. **The daemon is the already-bundled `engram` binary**, not a new build
   product. It is invoked as a hidden `engram _helper-daemon` subcommand. This
   avoids a second signed executable and a second Xcode target: the CLI is
   already bundled at `Contents/Helpers/engram` and signed with the app's
   identity by `bundle-cli.sh`. The daemon code itself lives in `EngramCore`
   (`HelperProtocol.swift`, `HelperDaemon.swift`) so both the CLI and the app
   share one definition of the XPC contract.

2. **A LaunchDaemon plist** (`org.klevan.Engram.helper.plist`) is bundled at
   `Contents/Library/LaunchDaemons/` (where `SMAppService.daemon(plistName:)`
   requires it), with `BundleProgram` → `Contents/Helpers/engram`,
   `ProgramArguments` ending in `_helper-daemon`, and a `MachServices` entry for
   the Mach service `org.klevan.Engram.helper`.

3. **The app** registers the daemon via `SMAppService.daemon(plistName:)`. On
   first use macOS routes the user to System Settings → Login Items for
   approval (`.requiresApproval`); once enabled the app opens an
   `NSXPCConnection(machServiceName:options:.privileged)` and calls the one
   helper method.

4. **The helper accepts no client-controlled paths.** Both ends of the symlink
   are fixed/derived inside the daemon: the destination is the constant
   `/usr/local/bin/engram`, and the source is the daemon's own
   `Bundle.main.executablePath` (i.e. the bundled CLI). So the helper is not a
   general root-symlink primitive — it can only install *itself*.

5. **The daemon validates every connecting client's code signature** before
   vending the object: it reads the connection's audit token, copies the
   guest `SecCode`, and checks it against the requirement `anchor apple generic
   and identifier "org.klevan.Engram" and certificate leaf[subject.OU] =
   "M2RXQJGK5A"` (team ID `M2RXQJGK5A`, from `.github/ExportOptions.plist`).
   Connections that fail validation are rejected.

The short-term Terminal fallback (`sudo engram install`) remains as a secondary
path for users who decline the System Settings approval.

## Consequences

- One-click privileged install on every Mac, no Homebrew assumption, no manual
  Terminal step in the happy path.
- The symlink keeps the CLI tracking the current app version across Sparkle
  updates (the short-term symlink change, now performed with privilege).
- **Signing-dependent and not locally verifiable.** Daemon registration, the
  System Settings approval, and the XPC code-signing check only work on a
  Developer-ID-signed, notarized build (ADR 0010); `swift build` / `make test`
  cannot exercise them. The team ID and bundle identifier are baked into the
  requirement string, so a re-org of either must update `HelperConstants`.
- New surface to keep signed: the daemon is the same `engram` binary, so no
  extra signing step, but the `Contents/Library/LaunchDaemons/` plist must be
  bundled (a Copy Files build phase) and the binary must remain signed with the
  team identity for the requirement check to pass.
- Mixing a root daemon entry point into the user-facing CLI binary widens that
  binary's role; it is mitigated by (4) and (5) — the daemon path takes no
  external input and refuses unverified callers — but it is a deliberate
  trade against shipping a second executable.
- Reversible: if the helper proves troublesome, the app falls back to the
  Terminal path and the daemon plist/subcommand can be dropped without touching
  storage or the integration model.
