#!/bin/bash
# Builds a signed tinywm.app and zips it for a GitHub release.
#   scripts/release.sh 0.1.0   → build/tinywm-0.1.0.zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TINYWM_VERSION="$VERSION" scripts/bundle-tinywm.sh

# ditto keeps the signature and extended attributes intact, unlike plain zip.
ZIP="build/tinywm-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/tinywm.app "$ZIP"
shasum -a 256 "$ZIP"
echo "Upload $ZIP to a GitHub release."
