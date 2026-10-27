#!/usr/bin/env bash
# Archives and exports dist/Dove.app (Developer ID, signed, ready for scripts/notarize.sh).
#
# Signing identity: automatic, through DEVELOPMENT_TEAM in project.yml. The App Group, the keychain
# group, iCloud and the File Provider all need a provisioning profile, so the export needs an Apple
# account: locally the one in Xcode, in CI the App Store Connect key (the same one notarize.sh uses).
#   - locally:  ./scripts/build-mac.sh
#   - in CI:    NOTARY_KEY_PATH=/abs/notary.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… ./scripts/build-mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is missing (brew install xcodegen)" >&2; exit 1; }

# project.yml is the source of truth; Dove.xcodeproj is generated and git-ignored.
VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)"
TEAM="$(sed -nE 's/^ *DEVELOPMENT_TEAM: *([A-Za-z0-9]+)/\1/p' project.yml | head -1)"
[[ -n "$VERSION" ]] || { echo "No MARKETING_VERSION in project.yml" >&2; exit 1; }
[[ -n "$TEAM" ]] || { echo "No DEVELOPMENT_TEAM in project.yml" >&2; exit 1; }
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "Dove $VERSION ($BUILD), team $TEAM"

xcodegen generate

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(-allowProvisioningUpdates
        -authenticationKeyPath "$NOTARY_KEY_PATH"
        -authenticationKeyID "${NOTARY_KEY_ID:?}"
        -authenticationKeyIssuerID "${NOTARY_ISSUER_ID:?}")
else
  AUTH=(-allowProvisioningUpdates)
fi

ARCHIVE="dist/DoveMac.xcarchive"
rm -rf "$ARCHIVE" dist/Dove.app
mkdir -p dist

xcodebuild archive \
  -project Dove.xcodeproj \
  -scheme DoveMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD"

# Only the Account Holder may create Developer ID profiles, which an App Store Connect key cannot do: in CI
# the export signs manually with the profiles Xcode made on the owner's Mac ("Mac Team Direct Provisioning
# Profile: <bundle ID>"), passed in MAC_PROFILES_DIR. Locally Xcode finds or makes them itself.
SIGNING="<key>signingStyle</key><string>automatic</string>"
if [[ -n "${MAC_PROFILES_DIR:-}" ]]; then
  PROFILES=""
  DECODED="$(mktemp)"
  for profile in "$MAC_PROFILES_DIR"/*.provisionprofile; do
    security cms -D -i "$profile" -o "$DECODED"
    APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$DECODED")"
    UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$DECODED")"
    PROFILES+="<key>${APP_ID#"$TEAM".}</key><string>$UUID</string>"
  done
  rm -f "$DECODED"
  [[ -n "$PROFILES" ]] || { echo "No profiles in $MAC_PROFILES_DIR" >&2; exit 1; }
  SIGNING="<key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict>$PROFILES</dict>"
fi

OPTS="$(mktemp)"
cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  $SIGNING
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath dist \
  -exportOptionsPlist "$OPTS" \
  "${AUTH[@]}"
rm -f "$OPTS"

[[ -d dist/Dove.app ]] || { echo "Export produced no dist/Dove.app" >&2; ls -la dist >&2; exit 1; }

# The extensions (DoveMacWidgets, DoveMacFiles) are signed inside the bundle; check the whole tree.
codesign --verify --deep --strict --verbose=2 dist/Dove.app
echo "Done: dist/Dove.app"
