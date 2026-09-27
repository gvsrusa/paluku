#!/bin/zsh
# Release build → (sign) → DMG → (notarize + staple) → SHA-256.
# Signing/notarization run only when credentials are present, so the same script works locally and in CI.
#
#   DEVELOPER_ID_APPLICATION  e.g. "Developer ID Application: Jane Doe (TEAMID1234)"  (identity in keychain)
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD  → notarytool credentials (app-specific password)
#   PALUKU_SELF_SIGN_IDENTITY  used when there's no Developer ID: our self-signed certificate's name (optional
#                           PALUKU_SIGN_KEYCHAIN). Keeps macOS permissions across updates; see docs/RELEASING.md.
#
# Output: dist/Paluku-<version>.dmg and dist/Paluku-<version>.dmg.sha256
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -n "${SKIP_BUILD:-}" ]] || scripts/build.sh Release  # CI builds before importing the signing key
APP=build/dd/Build/Products/Release/Paluku.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
DMG="dist/Paluku-$VERSION.dmg"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "→ signing with $DEVELOPER_ID_APPLICATION (hardened runtime)"
  codesign --force --deep --options runtime --timestamp \
    --entitlements App/Paluku.entitlements --sign "$DEVELOPER_ID_APPLICATION" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  SIGNED=1
elif [[ -n "${PALUKU_SELF_SIGN_IDENTITY:-}" ]]; then
  # Stable identity (identifier + our certificate): macOS keeps permissions across updates and the updater pins it.
  # Not notarized, so Gatekeeper still asks once on first launch.
  echo "→ signing with self-signed identity \"$PALUKU_SELF_SIGN_IDENTITY\" (hardened runtime)"
  KC_ARGS=()
  [[ -n ${PALUKU_SIGN_KEYCHAIN:-} ]] && KC_ARGS=(--keychain "$PALUKU_SIGN_KEYCHAIN")
  codesign --force --deep --options runtime --entitlements App/Paluku.entitlements "${KC_ARGS[@]}" --sign "$PALUKU_SELF_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  SIGNED=0
else
  echo "⚠︎ no signing identity: ad-hoc build (permissions reset on every update; see docs/RELEASING.md)"
  codesign --force --deep --options runtime --entitlements App/Paluku.entitlements --sign - "$APP"  # runtime blocks DYLD injection
  SIGNED=0
fi

echo "→ creating $DMG"
# Finder layout (background arrow, icon positions) via dmgbuild: writes .DS_Store directly, no Finder scripting,
# so it works on headless CI. Pinned, in a private venv.
VENV=build/dmgenv
[[ -x $VENV/bin/dmgbuild ]] || { python3 -m venv $VENV && $VENV/bin/pip install -q dmgbuild==1.6.7; }
BG=$(mktemp -d)
swift scripts/make-dmg-background.swift "$BG" $([[ $SIGNED == 0 ]] && echo --unsigned)
tiffutil -cathidpicheck "$BG/background.png" "$BG/background@2x.png" -out "$BG/background.tiff" 2>/dev/null
rm -f "$DMG"
HELP=()  # unsigned: a link that opens System Settings › Privacy & Security (via the website) for "Open Anyway"
[[ $SIGNED == 0 ]] && HELP=(-D "help=$PWD/scripts/If Paluku won't open.webloc")
$VENV/bin/dmgbuild -s scripts/dmg-settings.py -D app="$APP" -D background="$BG/background.tiff" "${HELP[@]}" "Paluku $VERSION" "$DMG"
rm -rf "$BG"
[[ $SIGNED == 1 ]] && codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"

if [[ $SIGNED == 1 && -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "→ notarizing (this can take a few minutes)"
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
else
  echo "⚠︎ notarization skipped (needs signing + APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD)"
fi

(cd dist && shasum -a 256 "Paluku-$VERSION.dmg" | tee "Paluku-$VERSION.dmg.sha256")  # basename so `shasum -c` works after download
echo "✓ $DMG"
