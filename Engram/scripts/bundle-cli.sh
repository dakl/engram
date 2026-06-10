#!/bin/bash
# Builds the engram CLI from the local SwiftPM package and bundles it into the
# app at Contents/MacOS/engram, signed to match the app. Run as an Xcode build
# phase so "update app → install latest CLI" holds.
set -euo pipefail

PACKAGE_DIR="$SRCROOT/.."
SCRATCH="$DERIVED_FILE_DIR/cli-build"

echo "note: building engram CLI for the app bundle"
swift build --package-path "$PACKAGE_DIR" --product engram -c release --scratch-path "$SCRATCH"

# NOTE: must NOT be Contents/MacOS — the app binary is "Engram" and the CLI is
# "engram", which collide on case-insensitive APFS and clobber the app binary.
SRC="$SCRATCH/release/engram"
DEST_DIR="$CODESIGNING_FOLDER_PATH/Contents/Helpers"
mkdir -p "$DEST_DIR"
cp -f "$SRC" "$DEST_DIR/engram"
chmod 0755 "$DEST_DIR/engram"

# The binary already carries an ad-hoc signature from `swift build`, which is
# enough to execute locally. Best-effort re-sign with the app's identity for
# notarized distribution; never fail the build if it can't (e.g. in script-phase
# env where the enclosing bundle isn't signed yet).
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp=none \
        --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST_DIR/engram" \
        || echo "warning: could not re-sign embedded engram (keeping ad-hoc signature)"
fi

echo "note: bundled engram → $DEST_DIR/engram"
