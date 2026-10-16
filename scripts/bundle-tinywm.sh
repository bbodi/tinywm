#!/bin/bash
# Builds a release binary and assembles a signed tinywm.app in ./build.
#
#   scripts/bundle-tinywm.sh            build/tinywm.app
#   scripts/bundle-tinywm.sh --install  also copy it to ~/Applications (quit tinywm first)
#
# Signing: macOS ties Accessibility and Screen Recording grants to the app's signature. An
# ad-hoc signature changes on every build, so macOS may ask again after each rebuild. The script
# signs with "tinywm self-signed" when that identity exists (scripts/make-signing-identity.sh),
# or with TINYWM_SIGN_IDENTITY when set.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${TINYWM_BUNDLE_ID:-dev.tinywm}"
VERSION="${TINYWM_VERSION:-0.1.0}"
IDENTITY="${TINYWM_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-certificate -c "tinywm self-signed" >/dev/null 2>&1; then
    IDENTITY="tinywm self-signed"
fi

swift build -c release --product tinywm
BIN="$(swift build -c release --show-bin-path)/tinywm"

APP="build/tinywm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/tinywm"

ICONSET="build/tinywm.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>tinywm</string>
    <key>CFBundleDisplayName</key><string>tinywm</string>
    <key>CFBundleExecutable</key><string>tinywm</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\"."
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc. macOS may ask for permissions again after each rebuild;"
    echo "run scripts/make-signing-identity.sh once to keep them."
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/tinywm.app"
    cp -R "$APP" "$HOME/Applications/tinywm.app"
    echo "Installed to ~/Applications/tinywm.app"
fi
