#!/bin/bash
# Records the README demo: hides other apps, opens tinywm's own source in the tinytext editor
# (from ../tinytext, or TINYTEXT_DIR), starts tinywm, plays the keys,
# and writes docs/demo.gif. It takes over the screen for about 40 seconds, then shows the hidden
# apps again. The terminal running it needs Accessibility and Screen Recording access; tinywm
# runs from this terminal, so it uses the same access.
set -euo pipefail
cd "$(dirname "$0")/../.."

swift build -c release --product tinywm >/dev/null
BIN="$(swift build -c release --show-bin-path)/tinywm"

DEMO="$(mktemp -d)"
TINYTEXT_DIR="${TINYTEXT_DIR:-../tinytext}"
(cd "$TINYTEXT_DIR" && go build -o "$DEMO/tt" .)
files=(Sources/StripModel/Strip.swift Sources/StripModel/Workspaces.swift
       Sources/StripEngine/StripEngine.swift Sources/tinywm/PictureMotion.swift README.md)

# Keep the recording free of anything personal: hide every other app and the desktop icons,
# check that it worked, and restore both afterwards.
HIDDEN=""
FRONT="$(swift scripts/demo/apps.swift front)"
ICONS="$(defaults read com.apple.finder CreateDesktop 2>/dev/null || echo unset)"
# Process IDs this script started. Only these are stopped, and only when above 0: kill with 0 or
# -1 would signal this whole script or every process the user owns.
WM=0
EDITORS=()
stop() { if [ "${1:-0}" -gt 0 ]; then kill "$1" 2>/dev/null || true; fi; }
# Finder picks up the desktop-icons setting only when it starts again.
restart_finder() {
    osascript -e 'tell application id "com.apple.finder" to quit' >/dev/null 2>&1 || true
    sleep 1
    open -b com.apple.finder
}
restore() {
    stop "$WM"
    for pid in ${EDITORS[@]+"${EDITORS[@]}"}; do stop "$pid"; done
    if [ "$ICONS" = unset ]; then defaults delete com.apple.finder CreateDesktop 2>/dev/null || true
    else defaults write com.apple.finder CreateDesktop "$ICONS"; fi
    restart_finder
    swift scripts/demo/apps.swift show $HIDDEN
}
trap restore EXIT
# Desktop icons go first: restarting Finder brings other apps back to the front.
defaults write com.apple.finder CreateDesktop -bool false
restart_finder
sleep 2
osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1 || true
# Some apps show themselves again a moment later, so hide, check and repeat a few times.
for attempt in 1 2 3; do
    HIDDEN="$HIDDEN $(swift scripts/demo/apps.swift hide "$FRONT")"
    sleep 1.5
    LEFT="$(swift scripts/demo/apps.swift check)"
    [ -z "$LEFT" ] && break
done
if [ -n "$LEFT" ]; then
    echo "These apps are still visible, so nothing was recorded:"; echo "$LEFT"; exit 1
fi

# A demo config that ignores every app but the editor, so hidden apps' windows stay out of the
# overview. XDG_CONFIG_HOME keeps it apart from your own config.
mkdir -p "$DEMO/config/tinywm"
echo "ignore = $(swift scripts/demo/apps.swift others)" > "$DEMO/config/tinywm/config"

# Your installed tinywm would fight the demo copy, so it is asked to quit.
osascript -e 'tell application id "dev.tinywm" to quit' >/dev/null 2>&1 || true
sleep 1
XDG_CONFIG_HOME="$DEMO/config" "$BIN" >/dev/null 2>&1 &
WM=$!
sleep 2

screencapture -v -V 34 -x "$DEMO/demo.mov" &
REC=$!
sleep 1
for f in "${files[@]}"; do "$DEMO/tt" "$f" >/dev/null 2>&1 & EDITORS+=("$!"); sleep 1.2; done
sleep 1
swift scripts/demo/keys.swift
wait $REC

swift scripts/demo/to-gif.swift "$DEMO/demo.mov" docs/demo.gif 800 12
echo "Recording: $DEMO/demo.mov"
ls -lh docs/demo.gif
