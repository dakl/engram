# 22. Privileged CLI install via a one-shot authenticated `osascript`

- **Status:** Accepted
- **Date:** 2026-06-22
- **Deciders:** Daniel Klevebring, Claude
- **Relates to:** ADR 0003 (non-sandboxed dev-tool app), issue #4

## Context

The app's "Install the engram CLI" button writes `/usr/local/bin/engram`.
That directory is on `/etc/paths` everywhere (so it's the correct target) but is
only user-writable on Intel Macs where Homebrew has `chown`ed `/usr/local`. On
Apple Silicon and on fresh macOS it stays root-owned, and the write fails with
`NSCocoaErrorDomain 513` / `EACCES`. `~/.local/bin` isn't a viable fallback —
it's not on the default `$PATH`, so the installed hooks (which reference the
absolute binary path) would silently break.

A short-term mitigation (separate change) switched the copy to a symlink — fixing
post-update version drift — and surfaced a "run `sudo engram install`" message on
failure. That keeps the failure legible but still drops the user to a terminal.
For a one-click install the app needs to perform the write with privilege.

We surveyed the privilege options and found there is **no** modern,
non-deprecated, leftover-free, Touch-ID-capable one-shot API — you pick two of
{modern, no persistent artifact, Touch ID}:

| Mechanism | Prompt | Touch ID | Leaves behind |
|---|---|---|---|
| `SMAppService.daemon` + XPC | Login Items toggle in System Settings | no | a registered root daemon, forever |
| `SMJobBless` + Authorization Services | native auth dialog | yes | a privileged helper tool |
| `AuthorizationExecuteWithPrivileges` | native auth dialog | yes | nothing — but deprecated/removed |
| `osascript … do shell script … with administrator privileges` | password prompt | **no¹** | nothing |

¹ We initially expected Touch ID here (the requesting process, `/usr/bin/osascript`,
is Apple-signed), but on-device testing showed `do shell script … with
administrator privileges` always presents a **password** prompt — it doesn't
route through the biometric-enabled authorization path. Touch ID for a privileged
file op in practice requires a helper (the Authorization Services / `SMJobBless`
route), which we deliberately don't take. The password prompt also names the
requester ("osascript wants to make changes"), which isn't customizable.

An `SMAppService` LaunchDaemon — initially prototyped here — is the wrong shape
for a one-shot symlink: it registers a *persistent* root daemon and forces the
user through a Login Items toggle (macOS Ventura's Background Task Management
consent), leaving a daemon registered forever for a once-ever action.

## Decision

Install the symlink with a single authenticated command, run through the
Apple-signed `osascript`:

```
/usr/bin/osascript -e 'do shell script
    "/bin/mkdir -p /usr/local/bin && /bin/ln -sfn <src> /usr/local/bin/engram"
    with administrator privileges'
```

- The app (`PrivilegedInstaller`) spawns `/usr/bin/osascript` as a subprocess.
  macOS shows the standard admin authentication dialog (a password prompt — not
  Touch ID; see the table note). Cancelling (`osascript` exit, error `-128`)
  returns the sheet to its confirm state; other non-zero exits surface the error
  plus the `sudo … install` terminal fallback.
- `<src>` is the bundled CLI at `Contents/Helpers/engram`; both paths are
  app-derived (never user input) and still shell-quoted + AppleScript-escaped so
  an unusual install location can't break or inject into the command.
- Nothing persists: no daemon, no Login Items entry, no helper tool in
  `/Library/PrivilegedHelperTools`, no XPC service, no extra entitlement. The app
  stays non-sandboxed (ADR 0003), which this approach requires.

## Consequences

- One authenticated dialog (a password prompt) and the machine is left exactly
  as before save for the symlink — matching a dev tool's "install once" mental
  model. No Touch ID (see the survey table); accepted as a fair trade for zero
  persistence.
- The symlink keeps the CLI tracking the current app version across Sparkle
  updates (the short-term symlink change, now performed with privilege).
- **Costs of the `osascript` route (accepted):** the auth dialog's wording isn't
  customizable and names the requester (`osascript`), so the in-app sheet
  explains what's about to happen first; and it's a fork/exec of a system binary
  rather than a typed Swift API. Each invocation re-authenticates — fine for a
  once-ever install.
- We forgo silent (no-prompt) re-runs. If Engram ever needs *repeated* silent
  privileged operations (e.g. an uninstaller, or re-linking on every app move), a
  persistent helper (`SMAppService`/`SMJobBless`) would become justified and
  warrant a new ADR; for now it's unjustified complexity. (A helper would also be
  the only way to get the Touch ID dialog, if that ever becomes a priority.)
- Verifiable locally: this is just a subprocess, so the flow runs on any signed
  dev build — no notarization or daemon registration required to exercise it.
