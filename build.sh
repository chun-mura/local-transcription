#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
export TMPDIR="${TMPDIR:-$PWD/.tmp}"
mkdir -p "$TMPDIR"

SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
SWIFTC=/usr/bin/swiftc

LOCAL_CERT="local-transcription-dev"
KEYCHAIN="$HOME/Library/Keychains/local-transcription-signing.keychain-db"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PASS_FILE="$(pwd)/.signing/signing-keychain-pass"

if [[ -f "$KEYCHAIN" && -f "$PASS_FILE" ]]; then
  "$SECURITY" unlock-keychain -p "$(cat "$PASS_FILE")" "$KEYCHAIN" >/dev/null
  "$SECURITY" list-keychains -d user -s "$KEYCHAIN" "$LOGIN_KEYCHAIN" >/dev/null
fi

# Apple Development（Team ID あり）があれば優先。画面収録 TCC に必要。
CERT_NAME=""
SIGN_KEYCHAIN_ARGS=()
if apple_line=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null | grep -F "Apple Development:" | head -1); then
  CERT_NAME=${apple_line#*\"}
  CERT_NAME=${CERT_NAME%\"*}
  echo "using Apple Development: $CERT_NAME"
elif "$SECURITY" find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F "$LOCAL_CERT" >/dev/null; then
  CERT_NAME="$LOCAL_CERT"
  SIGN_KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
  echo "using self-signed: $CERT_NAME（Team ID なし。画面収録が拒否されることがあります）"
else
  echo "signing identity がありません。" >&2
  echo "Xcode → Settings → Accounts で Apple Development 証明書を作るか、" >&2
  echo "./scripts/make-signing-identity.sh を実行してください。" >&2
  exit 1
fi

APP="dist/LocalTranscription.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
"$SWIFTC" -parse-as-library -O -target arm64-apple-macos26.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework Speech \
  -framework CoreMedia \
  -framework CoreGraphics \
  -framework Carbon \
  -framework ApplicationServices \
  Sources/Convert.swift \
  Sources/FrequentWords.swift \
  Sources/CaptionRead.swift \
  Sources/CaptionWatch.swift \
  Sources/SessionStore.swift \
  Sources/Transcribe.swift \
  Sources/Capture.swift \
  Sources/TitlePrompt.swift \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/LocalTranscription"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
"$CODESIGN" --force --sign "$CERT_NAME" "${SIGN_KEYCHAIN_ARGS[@]}" --identifier app.local.transcription "$APP"
INSTALL="$HOME/Applications/記録音.app"
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"
xattr -cr "$INSTALL"
"$CODESIGN" --force --sign "$CERT_NAME" "${SIGN_KEYCHAIN_ARGS[@]}" --identifier app.local.transcription "$INSTALL"
echo "built $APP"
echo "installed $INSTALL"
"$CODESIGN" -dv "$INSTALL" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature'
