#!/usr/bin/env bash
# Builds DevPulse.app into ./build
# Usage: ./build.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/DevPulse.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/DevPulse" "$APP/Contents/MacOS/DevPulse"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature – enough to run it locally
codesign --force --sign - "$APP" >/dev/null

echo "✓ Built $APP"
