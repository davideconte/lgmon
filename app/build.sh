#!/bin/bash
# Builds lgmon.app (universal), signs it with a Developer ID if available, and zips it.
#   ./build.sh                 build + sign
#   ./build.sh --notarize      also notarize: NOTARY_PROFILE (notarytool keychain profile)
#                              or ASC_KEY_ID + ASC_ISSUER_ID (+ ASC_KEY_PATH) for an App Store Connect API key
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
APP=build/lgmon.app

swift build -c release --arch arm64 --arch x86_64
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/lgmon" "$APP/Contents/MacOS/lgmon"
sed "s/VERSION/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

swift tools/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "No Developer ID found: ad-hoc signing (Gatekeeper will ask on first open)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" build/lgmon.zip
if [[ "${1:-}" == "--notarize" ]]; then
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
  else
    AUTH=(--key "${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  fi
  xcrun notarytool submit build/lgmon.zip "${AUTH[@]}" --wait
  xcrun stapler staple "$APP"
  rm build/lgmon.zip && ditto -c -k --keepParent "$APP" build/lgmon.zip
fi
echo "Built $APP ($VERSION)"
