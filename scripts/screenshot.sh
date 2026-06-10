#!/usr/bin/env bash
# Launch Engram against a seeded demo store and screenshot each lens.
# Window-with-shadow cutouts via `screencapture -l<id>` (id from winid.swift).
#
#   bash scripts/seed-demo.sh /tmp/engram-demo.sqlite
#   bash scripts/screenshot.sh [db-path] [out-dir]
#
# Permissions (one-time): the capturing terminal needs **Screen Recording**
# (System Settings ▸ Privacy & Security). Resizing the window + switching lenses
# uses System Events, which needs **Accessibility**; if not granted, you still get
# the default (List) shot — grant it for all four lenses.
set -uo pipefail

DB="${1:-/tmp/engram-demo.sqlite}"
OUT="${2:-docs}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name Engram.app -path '*/Build/Products/Debug/Engram.app' -not -path '*Index.noindex*' -type d 2>/dev/null | head -1)"
[ -n "$APP" ] || { echo "✗ built Engram.app not found — run 'make app' first" >&2; exit 1; }
[ -f "$DB" ] || { echo "✗ demo DB $DB not found — run scripts/seed-demo.sh first" >&2; exit 1; }
mkdir -p "$OUT"

echo "→ launching $APP on $DB"
osascript -e 'tell application "Engram" to quit' >/dev/null 2>&1 || true
sleep 1
ENGRAM_DB="$DB" "$APP/Contents/MacOS/Engram" >/dev/null 2>&1 &
sleep 4

# Try to frame the window to a clean size (needs Accessibility; non-fatal).
osascript >/dev/null 2>&1 <<'OSA' || echo "  (couldn't resize window — Accessibility not granted; using current size)"
tell application "Engram" to activate
delay 0.3
tell application "System Events" to tell process "Engram"
  set position of window 1 to {140, 120}
  set size of window 1 to {1180, 760}
end tell
OSA
sleep 1

capture() { # <lens-name>
  local id
  id="$(swift "$HERE/winid.swift" Engram 2>/dev/null)"
  if [ -z "$id" ]; then echo "  ✗ no Engram window for $1"; return 1; fi
  screencapture -o -l"$id" "$OUT/screenshot-$1.png" && echo "  ✓ $OUT/screenshot-$1.png"
}

# Default lens (List) — no Accessibility needed beyond the capture itself.
capture list

# Switch through the remaining lenses with ⌘2/3/4 (needs Accessibility).
for n in 2 3 4; do
  name=$([ "$n" = 2 ] && echo tags || { [ "$n" = 3 ] && echo map || echo activity; })
  if osascript -e "tell application \"System Events\" to tell process \"Engram\" to keystroke \"$n\" using command down" >/dev/null 2>&1; then
    sleep 1.5; capture "$name"
  else
    echo "  (skip $name — keystroke needs Accessibility permission)"; break
  fi
done

echo "done."