#!/usr/bin/env bash
# Builds build/Utter.app from the Swift package.
#
# Signing matters: macOS ties Accessibility and Input Monitoring grants to the
# app's code signature. An ad-hoc signature changes on every build, so each
# rebuild silently loses those permissions. Set SIGN_IDENTITY to a stable
# certificate (see README, "Keeping permissions across rebuilds") to avoid that.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Utter.app"

swift build -c "$CONFIGURATION" --product Utter
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Utter" "$APP/Contents/MacOS/Utter"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --identifier dev.utter.Utter "$APP"

if [ "$IDENTITY" = "-" ]; then
  echo "Built $APP (ad-hoc signed: permissions reset on each rebuild; see README)"
else
  echo "Built $APP (signed with \"$IDENTITY\")"
fi
