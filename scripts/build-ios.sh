#!/usr/bin/env bash
# Builds the iOS app for a release, two ways:
#
#   ./scripts/build-ios.sh unsigned   dist/Dove-<version>-unsigned.ipa, not signed at all: for people who
#                                     sign it themselves with a sideloading tool. No Apple account needed.
#   ./scripts/build-ios.sh upload     archives with Apple Distribution signing and uploads the build to
#                                     App Store Connect, where scripts/asc-notarize.py submits it for
#                                     notarization (AltStore PAL).
#
# `upload` needs an Apple account that may create App Store profiles: locally the one in Xcode, in CI the
# App Store Connect key (NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID, as in build-mac.sh) and the
# Apple Distribution certificate in the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
[[ "$MODE" == unsigned || "$MODE" == upload ]] || { echo "Usage: $0 unsigned|upload" >&2; exit 2; }
command -v xcodegen >/dev/null || { echo "xcodegen is missing (brew install xcodegen)" >&2; exit 1; }

# project.yml is the source of truth; Dove.xcodeproj is generated and git-ignored.
VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)"
TEAM="$(sed -nE 's/^ *DEVELOPMENT_TEAM: *([A-Za-z0-9]+)/\1/p' project.yml | head -1)"
[[ -n "$VERSION" ]] || { echo "No MARKETING_VERSION in project.yml" >&2; exit 1; }
[[ -n "$TEAM" ]] || { echo "No DEVELOPMENT_TEAM in project.yml" >&2; exit 1; }
# The same number as the Mac build. App Store Connect refuses a build number it has seen for this version.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "Dove iOS $VERSION ($BUILD), $MODE"

xcodegen generate
mkdir -p dist

if [[ "$MODE" == unsigned ]]; then
  DERIVED="dist/ios-unsigned"
  IPA="dist/Dove-$VERSION-unsigned.ipa"
  rm -rf "$DERIVED" "$IPA"
  xcodebuild build \
    -project Dove.xcodeproj \
    -scheme Dove \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  APP="$DERIVED/Build/Products/Release-iphoneos/Dove.app"
  [[ -d "$APP" ]] || { echo "No $APP" >&2; exit 1; }
  # An IPA is a zip with the app under Payload/.
  STAGE="$(mktemp -d)"
  mkdir "$STAGE/Payload"
  cp -R "$APP" "$STAGE/Payload/"
  (cd "$STAGE" && zip -qry ipa.zip Payload)
  mv "$STAGE/ipa.zip" "$IPA"
  rm -rf "$STAGE" "$DERIVED"
  echo "Done: $IPA"
  exit 0
fi

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(-allowProvisioningUpdates
        -authenticationKeyPath "$NOTARY_KEY_PATH"
        -authenticationKeyID "${NOTARY_KEY_ID:?}"
        -authenticationKeyIssuerID "${NOTARY_ISSUER_ID:?}")
else
  AUTH=(-allowProvisioningUpdates)
fi

ARCHIVE="dist/DoveIOS.xcarchive"
# The whole log goes to a file (CI keeps it as an artefact on failure); the errors are shown here.
LOG="dist/ios-archive.log"
mkdir -p dist
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project Dove.xcodeproj \
  -scheme Dove \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD" > "$LOG" 2>&1 \
  || { grep -E 'error:|\*\* ARCHIVE' "$LOG" | head -40; exit 1; }
grep -E '\*\* ARCHIVE' "$LOG"

OPTS="$(mktemp -t dove-export).plist"
cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath dist/ios-upload \
  -exportOptionsPlist "$OPTS" \
  "${AUTH[@]}"
rm -f "$OPTS"
echo "Uploaded: Dove iOS $VERSION ($BUILD)"
echo "BUILD=$BUILD"
