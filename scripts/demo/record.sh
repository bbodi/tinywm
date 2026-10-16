#!/bin/bash
# Records the README demo: hides other apps, starts tinywm, then plays the demo. The demo opens
# tinywm's own source in the tinytext editor (from ../tinytext, or TINYTEXT_DIR), a separate
# Ghostty window and a separate Firefox window with an empty profile, presses the keys and shows a
# caption for each feature. It writes docs/demo.gif and build/demo.mp4, with music. It takes over the screen
# for about a minute, then shows the hidden apps again. Turn on Do Not Disturb first, so no
# notification shows. The terminal running it needs Accessibility and Screen Recording access;
# tinywm runs from this terminal, so it uses the same access.
set -euo pipefail
cd "$(dirname "$0")/../.."

swift build -c release --product tinywm >/dev/null
BIN="$(swift build -c release --show-bin-path)/tinywm"

DEMO="$(mktemp -d)"
TINYTEXT_DIR="${TINYTEXT_DIR:-../tinytext}"
(cd "$TINYTEXT_DIR" && go build -o "$DEMO/tt" ./cmd/tinytext)
swiftc -O -o "$DEMO/tinywm-demo" scripts/demo/play.swift
swift scripts/make-icon.swift "$DEMO/icon.png" 512
files="Sources/StripModel/Strip.swift:Sources/StripEngine/StripEngine.swift:README.md"
# An empty Firefox profile that skips the welcome pages. Firefox, unlike a browser you have
# open, has no windows of yours for tinywm to bring back, so quit it before recording.
mkdir -p "$DEMO/browser"
cat > "$DEMO/browser/user.js" <<'PREFS'
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("trailhead.firstrun.didSeeAboutWelcome", true);
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
PREFS
: > "$DEMO/launched"

if pgrep -xq firefox; then echo "Quit Firefox first: the demo opens its own copy."; exit 1; fi

# Keep the recording free of anything personal: hide every other app and the desktop icons,
# check that it worked, and restore both afterwards.
HIDDEN=""
FRONT="$(swift scripts/demo/apps.swift front)"
ICONS="$(defaults read com.apple.finder CreateDesktop 2>/dev/null || echo unset)"
# Process IDs this script started. Only these are stopped, and only when above 0: kill with 0 or
# -1 would signal this whole script or every process the user owns.
WM=0
REC=0
stop() { if [ "${1:-0}" -gt 0 ]; then kill "$1" 2>/dev/null || true; fi; }
# Finder picks up the desktop-icons setting only when it starts again.
restart_finder() {
    osascript -e 'tell application id "com.apple.finder" to quit' >/dev/null 2>&1 || true
    sleep 1
    open -b com.apple.finder
}
restore() {
    if [ "$REC" -gt 0 ]; then kill -INT "$REC" 2>/dev/null || true; fi
    stop "$WM"
    # The apps the demo started, each checked against its name before it is quit.
    while read -r pid name; do swift scripts/demo/apps.swift quit "$pid" "$name"; done < "$DEMO/launched"
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

# A demo config that ignores every other app, so hidden apps' windows stay out of the overview.
# Ghostty and Firefox stay managed, since the demo opens its own copies. The saved layout is off,
# so your own layout file is neither read nor written. XDG_CONFIG_HOME keeps it apart from your
# own config.
mkdir -p "$DEMO/config/tinywm"
OTHERS="$(swift scripts/demo/apps.swift others | tr ',' '\n' | sed 's/^ *//' \
    | grep -vx -e com.mitchellh.ghostty -e org.mozilla.firefox | paste -sd, - | sed 's/,/, /g')"
printf 'restore-layout = off\nignore = %s, tinywm-demo\n' "$OTHERS" > "$DEMO/config/tinywm/config"

# Your installed tinywm would fight the demo copy, so it is asked to quit.
osascript -e 'tell application id "dev.tinywm" to quit' >/dev/null 2>&1 || true
sleep 1
XDG_CONFIG_HOME="$DEMO/config" "$BIN" >/dev/null 2>&1 &
WM=$!
sleep 2

# An app can show itself again after it was hidden, so what is really on screen is checked last.
SHOWN="$(swift scripts/demo/apps.swift onscreen)"
if [ -n "$SHOWN" ]; then
    echo "These apps show a window, so nothing was recorded. Quit them and try again:"; echo "$SHOWN"; exit 1
fi
screencapture -v -x -D 1 "$DEMO/demo.mov" </dev/null >/dev/null 2>&1 &
REC=$!
sleep 1
DEMO_TT="$DEMO/tt" DEMO_FILES="$files" DEMO_TERMINAL="$PWD/scripts/demo/terminal.sh" \
    DEMO_BROWSER_PROFILE="$DEMO/browser" DEMO_ICON="$DEMO/icon.png" DEMO_LAUNCHED="$DEMO/launched" \
    "$DEMO/tinywm-demo"
sleep 0.5
# screencapture finishes the file when it gets an interrupt, as with Control-C.
if [ "$REC" -gt 0 ]; then kill -INT "$REC"; fi
wait "$REC" || true
REC=0

swift scripts/demo/to-gif.swift "$DEMO/demo.mov" docs/demo.gif 720 10
mkdir -p build
swift scripts/demo/to-mp4.swift "$DEMO/demo.mov" "$DEMO/silent.mp4"
swift scripts/demo/music.swift "$DEMO/music.wav" "$DEMO/silent.mp4"
swift scripts/demo/add-music.swift "$DEMO/silent.mp4" "$DEMO/music.wav" build/demo.mp4
echo "Recording: $DEMO/demo.mov"
ls -lh docs/demo.gif build/demo.mp4
