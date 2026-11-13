#!/usr/bin/env bash
# Builds DevPulse.app into ./build
# Usage: ./build.sh [release|debug]
#   release – universal binary (Apple Silicon + Intel)
#   debug   – native architecture only (faster)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/DevPulse.app"
BIN="build/DevPulse"
mkdir -p build

if [ "$CONFIG" = "release" ]; then
    for ARCH in arm64 x86_64; do
        swift build -c release --triple "$ARCH-apple-macosx13.0"
    done
    lipo -create \
        ".build/arm64-apple-macosx/release/DevPulse" \
        ".build/x86_64-apple-macosx/release/DevPulse" \
        -output "$BIN"
else
    swift build -c "$CONFIG"
    cp "$(swift build -c "$CONFIG" --show-bin-path)/DevPulse" "$BIN"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv "$BIN" "$APP/Contents/MacOS/DevPulse"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature – enough to run it locally
codesign --force --sign - "$APP" >/dev/null

echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/DevPulse"))"
