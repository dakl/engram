# 10. In-app updates via Sparkle, released from the public engram repo

- **Status:** Accepted
- **Date:** 2026-06-03
- **Deciders:** Daniel Klevebring
- **Extends:** [0003](0003-mac-app-distribution-model.md) (direct distribution via
  Developer ID + notarization, not the Mac App Store).

## Context

ADR 0003 settled that the macOS app is distributed directly, outside the Mac App
Store. It did not say **how users get the app or how they receive updates**. We
want the same experience we already ship in the Electron apps `codez` and
`papershelf`: a Settings pane with *Check for updates*, a visible available
version, download progress, and *install & relaunch*, plus quiet periodic
background checks.

Those apps use `electron-updater` against public GitHub Releases. Engram is a
**native SwiftUI app**, so that stack does not apply. The native-macOS
equivalent — and the framework the whole Squirrel/`electron-updater` lineage
descends from — is **[Sparkle 2](https://sparkle-project.org/)**. Sparkle fits
Engram cleanly: it is happiest in a **non-sandboxed** app (which we are, per
0003), it EdDSA-signs each update, and it exposes a programmatic API
(`SPUUpdater`) that binds directly into a SwiftUI Settings pane — no WebView.

One constraint shapes the topology: an updater needs the appcast feed and the
binaries to be **publicly fetchable**, and a shipped app cannot carry a
credential. Rather than split a private source repo from a separate public
releases repo (which would need a cross-repo deploy key and artifact syncing),
we **make the `engram` repo public** and release directly from it — the same
single-repo model codez and papershelf already use. The source is a local
developer tool with no secrets in it, so publishing it is acceptable.

A second constraint is operational: because the repo is public, **standard
GitHub-hosted macOS runners are free** (no minute cap), so the build/sign/
notarize/publish pipeline runs in **GitHub Actions**, not on the maintainer's
laptop. CI building a tagged ref also makes "released code is committed and
pushed" a structural guarantee. The signing material the runner needs
(Developer ID cert, notarization credentials, Sparkle private key) is stored as
encrypted repo secrets; the maintainer still holds the originals in their
Keychain and backs them up offline.

## Decision

**Adopt Sparkle 2 for in-app updates, fed by an appcast on the public `engram`
repo's GitHub Pages, and publish releases from a GitHub Actions workflow in that
same repo.**

### Update framework
- Add **Sparkle 2** as a Swift Package Manager dependency of the app target.
- Bake into `Info.plist`:
  - `SUFeedURL` → the appcast served by the engram repo's GitHub Pages, e.g.
    `https://dakl.github.io/engram/appcast.xml` (movable to a custom domain
    later without an app change beyond the URL).
  - `SUPublicEDKey` → the **public** half of an EdDSA key pair.
  - `SUEnableAutomaticChecks` → default on; `SUScheduledCheckInterval` set for
    quiet periodic checks (mirroring codez's cadence, order of hours).
- The **private** EdDSA key (created by Sparkle's `generate_keys`) is held in the
  maintainer's Keychain, backed up offline, and provided to CI as the
  `SPARKLE_PRIVATE_KEY` secret. It is **never committed**. Losing it means future
  updates can no longer be signed for the installed public key.

### Settings pane
- An **Updates** section in the app's Settings, driven by a
  `SPUStandardUpdaterController`: *Check now*, an "automatically check"
  toggle, current version, last-checked time, and Sparkle's built-in
  download/progress/install UI. This reproduces the codez/papershelf UX
  natively.

### Release topology
- The **`engram` repo is made public** and is the single home for source,
  releases, the appcast, and the website (the codez/papershelf model):
  - **GitHub Releases** hold the signed, notarized, stapled
    `Engram-X.Y.Z.zip` (zip, not DMG, so Sparkle can self-replace without user
    interaction), tagged `vX.Y.Z`.
  - **GitHub Pages** (served from the repo's `/docs` folder on `main`) hosts
    `appcast.xml` **and** the app's landing/download website.
  - Before flipping visibility, the git **history is audited for secrets**; the
    Sparkle private key, Developer ID cert, and notarization credentials live
    only in the maintainer's Keychain and are never committed.

### Release flow (CI)
- A small local helper (`make release-patch|release-minor|release-major`) only
  **bumps** `MARKETING_VERSION` + monotonically bumps `CURRENT_PROJECT_VERSION`
  (Sparkle orders updates by `CFBundleVersion`), commits, and **pushes a
  `vX.Y.Z` tag**. It does no signing, and a preflight gate refuses to run on a
  dirty or unpushed tree.
- The tag push triggers a **GitHub Actions workflow** on a `macos-latest`
  runner (also allowed via `workflow_dispatch`). It is **never** wired to
  `pull_request`/`pull_request_target`, so secrets are unreachable from fork
  PRs. The workflow:
  1. Checks out the tagged ref (so the release is provably a committed, pushed
     commit) and embeds the git SHA in the build.
  2. Imports `CSC_LINK` (base64 of the Developer ID `.p12`, with
     `CSC_KEY_PASSWORD`) into a throwaway keychain it creates and deletes per run.
  3. `xcodebuild archive` + export with the **Developer ID Application** identity
     and hardened runtime (the bundled `Contents/Helpers/engram` CLI is signed
     as part of the bundle, per 0003).
  4. Notarizes via `xcrun notarytool submit --wait` using `APPLE_ID` /
     `APPLE_TEAM_ID` / `APP_SPECIFIC_PASSWORD`, then `xcrun stapler staple`.
  5. Zips the stapled `.app` and runs Sparkle's `sign_update` (fed
     `SPARKLE_PRIVATE_KEY`) to produce the EdDSA signature + length.
  6. Creates the GitHub Release for the tag and uploads the zip, then prepends a
     new entry to `docs/appcast.xml` (a stdlib script) and pushes it to `main`,
     which GitHub Pages serves.
- **Required GitHub Actions secrets** (reconciled with `release.yml` — the names
  in an earlier draft of this ADR were corrected here): `CSC_LINK`,
  `CSC_KEY_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APP_SPECIFIC_PASSWORD`,
  `SPARKLE_PRIVATE_KEY`.
- **Prerequisites:** an Apple Developer Program membership and a Developer ID
  Application certificate, exported as a `.p12` for the secret above.

## Consequences

**Positive**
- Same update UX as codez/papershelf, implemented natively, with no WebView.
- **Single repo** owns source, releases, appcast, and the marketing site — no
  cross-repo deploy key or artifact syncing.
- **CI builds a tagged ref**, so every release provably maps to a committed,
  pushed commit, built in a pristine environment — not tied to one laptop.
- A public repo gets **free macOS runners**, so the 10× minute multiplier that
  would cap a private-repo build does not apply.

**Negative / trade-offs**
- **Source becomes public.** Irreversible in practice (clones/forks/indexing
  persist). Mitigated by auditing history for secrets before flipping
  visibility and keeping all signing material out of the repo.
- **Signing keys live as repo secrets.** The Developer ID cert, notarization
  password, and Sparkle private key are stored in GitHub Actions secrets — a
  second copy off the maintainer's machine. Mitigated by encrypting at rest,
  never running secret-bearing jobs on fork-triggered events
  (`pull_request`/`pull_request_target`), and restricting triggers to tag-push /
  `workflow_dispatch`.
- **Key custody risk**: the Sparkle private key and Developer ID cert are single
  points of failure; the maintainer's originals live only in the local Keychain
  (not synced to iCloud) and must be backed up offline.
- Requires an **Apple Developer Program** membership ($99/yr) for Developer ID +
  notarization.
- Sparkle replaces the app bundle, which refreshes the **bundled** CLI, but the
  separately-installed `/usr/local/bin/engram` does not auto-update; the app may
  optionally re-run `engram install` after an update (follow-up, not required by
  this ADR).
