#!/bin/bash
# Builds tinywm.app signed with the Developer ID, notarizes it and zips it for a GitHub release.
#   scripts/release.sh 0.1.0              build, notarize, staple → build/release/tinywm-0.1.0.zip
#   scripts/release.sh 0.1.0 --finish <id>  wait for a submission already sent, then staple and zip
#
# Needs your Apple team ID in TINYWM_TEAM_ID, and the notary login in the keychain once:
#   xcrun notarytool store-credentials tinywm-notary --apple-id <Apple ID> --team-id "$TINYWM_TEAM_ID"
#
# The release app lives in build/release, apart from build/tinywm.app, which every local build
# replaces. Apple's approval only fits the exact app that was sent.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--finish <submission id>]}"
PROFILE="${TINYWM_NOTARY_PROFILE:-tinywm-notary}"
OUT="build/release"
APP="$OUT/tinywm.app"
SUBMIT="$OUT/tinywm-$VERSION-notarize.zip"

if [ "${2:-}" = "--finish" ]; then
    ID="${3:?usage: scripts/release.sh <version> --finish <submission id>}"
    [ -d "$APP" ] || { echo "$APP is missing; it must be the app that was sent."; exit 1; }
    xcrun notarytool wait "$ID" --keychain-profile "$PROFILE"
else
    TEAM="${TINYWM_TEAM_ID:?set TINYWM_TEAM_ID to your Apple team ID}"
    # The certificate's fingerprint, since the name's accented letter can be stored in more than one way.
    IDENTITY="$(security find-identity -v -p codesigning | awk -v team="($TEAM)\"" '/Developer ID Application/ && index($0, team) { print $2; exit }')"
    [ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate for team $TEAM in the keychain."; exit 1; }

    TINYWM_VERSION="$VERSION" TINYWM_SIGN_IDENTITY="$IDENTITY" TINYWM_HARDENED=1 scripts/bundle-tinywm.sh
    rm -rf "$OUT"
    mkdir -p "$OUT"
    ditto build/tinywm.app "$APP"
    codesign --verify --strict --verbose=2 "$APP"

    # ditto keeps the signature and extended attributes intact, unlike plain zip.
    ditto -c -k --keepParent "$APP" "$SUBMIT"
    echo "If this wait stops, finish later with: scripts/release.sh $VERSION --finish <id shown below>"
    xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
fi

# Stapling attaches Apple's approval to the app, so it opens without a network check.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# The fixed name lets releases/latest/download/tinywm.zip always point to the newest release.
ZIP="$OUT/tinywm-$VERSION.zip"
rm -f "$ZIP" "$OUT/tinywm.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ZIP" "$OUT/tinywm.zip"
shasum -a 256 "$ZIP"
echo "Upload $ZIP and $OUT/tinywm.zip to the GitHub release v$VERSION."
