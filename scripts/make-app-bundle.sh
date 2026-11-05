#!/usr/bin/env bash
# Builds ImacDisplaySender.app (release) into ./build/, ad-hoc codesigned, so
# the Screen Recording grant attaches to the app rather than to Terminal.
#
#   scripts/make-app-bundle.sh
#
# Environment:
#   BUNDLE_ID           CFBundleIdentifier (default io.github.mrichard91.imac-display-sender)
#   VERSION             CFBundleShortVersionString (default 0.1.0)
#   BUILD_NUMBER        CFBundleVersion (default 1)
#   CODESIGN_IDENTITY   signing identity (default "-" = ad-hoc)
#   SWIFT_BUILD_FLAGS   extra flags for every swift build call. An explicit
#                       --build-system disables automatic engine fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:-io.github.mrichard91.imac-display-sender}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
OUT="$ROOT/build"
APP="$OUT/ImacDisplaySender.app"

cd "$ROOT"
read -r -a BUILD_FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"
# The +-expansion keeps an empty array legal under `set -u` in bash 3.2.
swift_build() { swift build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} "$@"; }

echo "==> swift build -c release ${SWIFT_BUILD_FLAGS:-}"
# Recent SwiftPM versions can fail to initialize the default engine with the
# Command Line Tools alone. Retry this specific failure, preserving other flags
# and using the same engine for both products and --show-bin-path.
BUILD_SYSTEM_EXPLICIT=false
for flag in ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}; do
    case "$flag" in
        --build-system|--build-system=*) BUILD_SYSTEM_EXPLICIT=true ;;
    esac
done
BUILD_LOG="$(mktemp -t imac-display-build)"
trap 'rm -f "$BUILD_LOG"' EXIT
if swift_build --product ImacDisplaySender 2>&1 | tee "$BUILD_LOG"; then
    :
else
    BUILD_STATUS=$?
    if [ "$BUILD_SYSTEM_EXPLICIT" = false ] &&
        grep -q 'Could not initialize build system' "$BUILD_LOG" &&
        grep -q 'Unknown error parsing property list' "$BUILD_LOG"; then
        echo "==> default build engine failed to initialize; retrying with --build-system native"
        BUILD_FLAGS+=(--build-system native)
        swift_build --product ImacDisplaySender
    else
        exit "$BUILD_STATUS"
    fi
fi
rm -f "$BUILD_LOG"
trap - EXIT
swift_build --product idp-probe
BIN="$(swift_build --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ImacDisplaySender" "$APP/Contents/MacOS/ImacDisplaySender"
cp "$BIN/idp-probe" "$OUT/idp-probe"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ImacDisplaySender</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>iMac Display Sender</string>
    <key>CFBundleDisplayName</key>
    <string>iMac Display Sender</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>iMac Display Sender captures its virtual display and streams it to your receiver.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>iMac Display Sender connects to a display receiver on your local network.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign ($CODESIGN_IDENTITY)"
codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> done"
echo "    app:   $APP"
echo "    probe: $OUT/idp-probe"
