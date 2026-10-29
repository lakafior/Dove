#!/usr/bin/env bash
# Regenerates docs/screenshots/*.png: Dove in demo mode (`-demo`, Debug builds only), made-up public-domain content,
# no accounts. The iPhone tour runs on its own simulator ("Dove Screenshots", iPhone 18 Pro Max, 6.9", erased first),
# the Mac tour on this Mac. Demo mode touches none of the Mac app's real Keychain items, files or defaults, but the
# UI test quits a running Dove first (same bundle ID): save nothing in it before running this.
#   ./scripts/screenshots.sh            # both
#   ./scripts/screenshots.sh ios        # iPhone only
#   ./scripts/screenshots.sh mac        # Mac only
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is missing (brew install xcodegen)" >&2; exit 1; }

WHICH="${1:-all}"
SIMULATOR="Dove Screenshots"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"
OUT="docs/screenshots"
DERIVED=".build/DerivedData"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcodegen generate

run_ios() {
  local udid
  udid="$(xcrun simctl list devices -j | python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if d['name'] == sys.argv[1] and d['isAvailable']: print(d['udid']); sys.exit()
" "$SIMULATOR")"
  [[ -n "$udid" ]] || udid="$(xcrun simctl create "$SIMULATOR" "$DEVICE_TYPE")"
  echo "iPhone: $SIMULATOR ($udid)"
  # A clean device every time: nothing from an earlier run, nobody's real data.
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl erase "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcodebuild -project Dove.xcodeproj -scheme DoveScreenshots -destination "id=$udid" -derivedDataPath "$DERIVED" \
    -resultBundlePath "$WORK/ios.xcresult" test | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" || true
  xcrun simctl shutdown "$udid" || true
}

run_mac() {
  echo "Mac: this Mac (the tour opens Dove windows; leave the mouse alone)"
  xcodebuild -project Dove.xcodeproj -scheme DoveMacScreenshots -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" -resultBundlePath "$WORK/mac.xcresult" -allowProvisioningUpdates test \
    | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" || true
}

case "$WHICH" in
  ios) run_ios ;;
  mac) run_mac ;;
  all) run_ios; run_mac ;;
  *) echo "usage: $0 [ios|mac]" >&2; exit 1 ;;
esac

# The tests keep each screenshot as an attachment named after the file (`Screenshot.save`); the result bundles also
# hold screen recordings of the whole display, so only the named PNGs leave $WORK.
mkdir -p "$OUT"
count=0
for bundle in "$WORK"/*.xcresult; do
  [[ -e "$bundle" ]] || continue
  export="${bundle%.xcresult}-attachments"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$export" >/dev/null
  while IFS=$'\t' read -r file name; do
    cp "$export/$file" "$OUT/$name.png"
    count=$((count + 1))
  done < <(python3 -c "
import json, re, sys
for test in json.load(open(sys.argv[1])):
    for attachment in test['attachments']:
        match = re.match(r'((?:iphone|mac)-[a-z]+)_\\d+_', attachment.get('suggestedHumanReadableName', ''))
        if match and attachment['exportedFileName'].endswith('.png'):
            print(attachment['exportedFileName'] + '\\t' + match.group(1))
" "$export/manifest.json")
done
echo "$count screenshots in $OUT"
[[ $count -gt 0 ]]
