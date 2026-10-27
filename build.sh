#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/LocalTranscription.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O -target arm64-apple-macos26.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework Speech \
  -framework CoreMedia \
  -framework CoreGraphics \
  -framework Carbon \
  Sources/Convert.swift \
  Sources/Replace.swift \
  Sources/SessionStore.swift \
  Sources/Transcribe.swift \
  Sources/Capture.swift \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/LocalTranscription"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
INSTALL="$HOME/Applications/記録音.app"
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"
xattr -cr "$INSTALL"
codesign --force --sign - "$INSTALL"
echo "built $APP"
echo "installed $INSTALL"
