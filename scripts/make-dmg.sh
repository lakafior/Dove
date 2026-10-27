#!/usr/bin/env bash
# Builds dist/Dove.dmg from dist/Dove.app plus a link to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Dove.app"
DMG="dist/Dove.dmg"
# CI passes SIGN_ID from the imported certificate; locally, find the Developer ID identity.
# An unsigned DMG cannot be stapled, so this is not optional.
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  SIGN_ID="${SIGN_ID:--}"
fi
echo "Signing the DMG as: $SIGN_ID"
[[ -d "$APP" ]] || { echo "No $APP, run scripts/build-mac.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Dove.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Dove" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
[[ "$SIGN_ID" != "-" ]] && codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
echo "Done: $DMG"
