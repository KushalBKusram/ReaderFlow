#!/usr/bin/env bash
# Builds ReaderFlow.app in Release configuration, ad-hoc signs it (no Apple
# Developer ID required), and packages it into a drag-to-Applications DMG
# under macos/build/. Run from anywhere; paths are resolved relative to
# this script.
#
# This produces an ad-hoc signed, non-notarized build. Downloaded from
# GitHub, macOS marks it quarantined and Gatekeeper will require either
# right-click > Open on first launch, or System Settings > Privacy &
# Security > Open Anyway. That's expected without a paid Developer ID.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="ReaderFlowMac.xcodeproj"
SCHEME="ReaderFlow"
APP_NAME="ReaderFlow.app"
BUILD_DIR="$(pwd)/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building $SCHEME (Release)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED_DATA" build

APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
BUILD_NUMBER=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion)
echo "==> Built version $VERSION ($BUILD_NUMBER)"

echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --verbose "$APP_PATH"

STAGE_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

DMG_NAME="ReaderFlow-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
rm -f "$DMG_PATH"
echo "==> Creating $DMG_NAME…"
hdiutil create -volname "ReaderFlow $VERSION" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" -quiet

echo "==> Done: $DMG_PATH"
