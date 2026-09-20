#!/bin/sh
set -eu
APP=${1:-dist/herdrorb.app}
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" | /usr/bin/grep -qx 'io.github.andrewjedi.herdrorb'
test -x "$APP/Contents/MacOS/HerdrOrb"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/SwiftTerm-LICENSE"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -d "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
test -f "$APP/Contents/Resources/HerdrOrb_HerdrOrb.bundle/ObservatoryBackground.png"
codesign --verify --deep --strict "$APP"
echo 'Application resources and code signature verified.'
