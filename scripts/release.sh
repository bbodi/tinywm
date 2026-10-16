#!/bin/bash
# Builds tinywm.app signed with the Developer ID, notarizes it and zips it for a GitHub release.
#   scripts/release.sh 0.1.0   → build/tinywm-0.1.0.zip and build/tinywm.zip
#
# Needs your Apple team ID in TINYWM_TEAM_ID, and the notary login in the keychain once:
#   xcrun notarytool store-credentials tinywm-notary --apple-id <Apple ID> --team-id "$TINYWM_TEAM_ID"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TEAM="${TINYWM_TEAM_ID:?set TINYWM_TEAM_ID to your Apple team ID}"
# The certificate's fingerprint, since the name's accented letter can be stored in more than one way.
IDENTITY="$(security find-identity -v -p codesigning | awk -v team="($TEAM)\"" '/Developer ID Application/ && index($0, team) { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate for team $TEAM in the keychain."; exit 1; }
PROFILE="${TINYWM_NOTARY_PROFILE:-tinywm-notary}"
APP="build/tinywm.app"

TINYWM_VERSION="$VERSION" TINYWM_SIGN_IDENTITY="$IDENTITY" TINYWM_HARDENED=1 scripts/bundle-tinywm.sh
codesign --verify --strict --verbose=2 "$APP"

# ditto keeps the signature and extended attributes intact, unlike plain zip.
SUBMIT="build/tinywm-$VERSION-notarize.zip"
rm -f "$SUBMIT"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
rm -f "$SUBMIT"

# Stapling attaches Apple's approval to the app, so it opens without a network check.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# The fixed name lets releases/latest/download/tinywm.zip always point to the newest release.
ZIP="build/tinywm-$VERSION.zip"
rm -f "$ZIP" build/tinywm.zip
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ZIP" build/tinywm.zip
shasum -a 256 "$ZIP"
echo "Upload $ZIP and build/tinywm.zip to the GitHub release v$VERSION."
