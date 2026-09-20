#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh build-app.sh
APP_VERSION=$(cat VERSION)
APP_ARCH=${APP_ARCH:-$(uname -m)}
APP="dist/herdrorb.app"
ARCHIVE="dist/herdrorb-$APP_VERSION-$APP_ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
if [ "${SIGNING_IDENTITY:--}" != '-' ]; then
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile}"
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
  SIGNING_STATUS='Developer ID signed and notarized'
else
  SIGNING_STATUS='Ad-hoc signed developer beta; not Developer ID signed or notarized'
fi
(cd dist && shasum -a 256 "herdrorb-$APP_VERSION-$APP_ARCH.zip" > "herdrorb-$APP_VERSION-$APP_ARCH.zip.sha256")
printf '%s\n' "$SIGNING_STATUS" > "dist/signing-status.txt"
printf 'Packaged %s\n%s\n' "$ARCHIVE" "$SIGNING_STATUS"
