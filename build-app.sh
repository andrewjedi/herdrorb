#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP_VERSION=$(cat VERSION)
APP_BUILD=${APP_BUILD:-2}
APP_ARCH=${APP_ARCH:-$(uname -m)}
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
case "$APP_ARCH" in arm64|x86_64) ;; *) echo 'APP_ARCH must be arm64 or x86_64' >&2; exit 1;; esac
case "$APP_BUILD" in ''|*[!0-9]*) echo 'APP_BUILD must be an integer' >&2; exit 1;; esac
swift build -c release --arch "$APP_ARCH" --product HerdrOrb
BIN_DIR=$(swift build -c release --arch "$APP_ARCH" --show-bin-path)
APP="$(pwd)/dist/herdrorb.app"
# A fresh staging directory prevents obsolete files from entering a release.
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/herdrorb-bundle.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
BUNDLE="$STAGING/herdrorb.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/HerdrOrb" "$BUNDLE/Contents/MacOS/HerdrOrb"
cp -R "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$BUNDLE/Contents/Resources/"
cp -R "$BIN_DIR/HerdrOrb_HerdrOrb.bundle" "$BUNDLE/Contents/Resources/"
cp .build/checkouts/SwiftTerm/LICENSE "$BUNDLE/Contents/Resources/SwiftTerm-LICENSE"
cp LICENSE THIRD_PARTY_NOTICES.md "$BUNDLE/Contents/Resources/"
swift scripts/make-icon.swift "$STAGING/AppIcon.iconset"
iconutil -c icns "$STAGING/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
# Convert the prerelease tag to an Apple bundle version (numeric components only).
BUNDLE_VERSION=${APP_VERSION%%-*}
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HerdrOrb</string>
<key>CFBundleIdentifier</key><string>io.github.andrewjedi.herdrorb</string>
<key>CFBundleName</key><string>herdrorb</string>
<key>CFBundleDisplayName</key><string>herdrorb</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$BUNDLE_VERSION</string>
<key>CFBundleVersion</key><string>$APP_BUILD</string>
<key>HerdrOrbReleaseVersion</key><string>$APP_VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Andrew Thompson. MIT licensed. Independent of Herdr.</string>
</dict></plist>
PLIST
if [ "$SIGNING_IDENTITY" = '-' ]; then
  codesign --force --sign - "$BUNDLE"
else
  case "$SIGNING_IDENTITY" in 'Developer ID Application:'*) ;; *) echo 'Distribution signing requires a Developer ID Application identity' >&2; exit 1;; esac
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BUNDLE/Contents/MacOS/HerdrOrb"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BUNDLE"
fi
codesign --verify --deep --strict "$BUNDLE"
mkdir -p dist
if [ -d "$APP" ]; then chmod -R u+w "$APP"; rm -rf "$APP"; fi
mv "$BUNDLE" "$APP"
printf 'Built %s (%s)\n' "$APP" "$APP_ARCH"
