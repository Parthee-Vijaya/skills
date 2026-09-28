#!/bin/bash
# Builds Bumlebee.app from the Swift package.
#
#   ./Scripts/build-app.sh             build/Bumlebee.app (+ build/Bumlebee.zip)
#   ./Scripts/build-app.sh --install   also copies it to /Applications and starts it
#
# Optional environment:
#   FFMPEG_PATH=/path/to/ffmpeg   bundle a (static) ffmpeg inside the app
#   UNIVERSAL=1                   build for both Apple silicon and Intel
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Bumlebee.app"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "› Compiling"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Bumlebee" "$APP/Contents/MacOS/Bumlebee"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

echo "› Drawing icon"
rm -rf build/AppIcon.iconset
swift Scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${FFMPEG_PATH:-}" ]]; then
  echo "› Bundling ffmpeg from $FFMPEG_PATH"
  cp "$FFMPEG_PATH" "$APP/Contents/MacOS/ffmpeg"
  chmod +x "$APP/Contents/MacOS/ffmpeg"
fi

echo "› Signing (ad hoc)"
codesign --force --deep --sign - "$APP"

(cd build && rm -f Bumlebee.zip && ditto -c -k --keepParent Bumlebee.app Bumlebee.zip)
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "› Installing to /Applications"
  pkill -x Bumlebee 2>/dev/null || true
  rm -rf /Applications/Bumlebee.app
  cp -R "$APP" /Applications/
  open /Applications/Bumlebee.app
  echo "✓ Bumlebee is running – look for the honeycomb in the menu bar"
fi
