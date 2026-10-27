#!/bin/zsh
# Builds Orbit.app (universal: Apple Silicon + Intel) and installs it into ~/Applications.
#
#   ./build.sh               build and install
#   ./build.sh --no-install  build only (output: build/Orbit.app)
set -euo pipefail
cd "${0:A:h}"

INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

APP="build/Orbit.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" \
    Sources/Orbit.swift -o "build/Orbit-$arch"
done
lipo -create build/Orbit-arm64 build/Orbit-x86_64 -output "$APP/Contents/MacOS/Orbit"
rm build/Orbit-arm64 build/Orbit-x86_64

echo "→ icon"
ICONSET=build/AppIcon.iconset && mkdir -p "$ICONSET"
swift make_icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"   # ad-hoc signature (no Apple Developer account needed)

if (( INSTALL )); then
  echo "→ installing to ~/Applications"
  mkdir -p ~/Applications
  rm -rf ~/Applications/Orbit.app
  cp -R "$APP" ~/Applications/
  echo "✓ done: ~/Applications/Orbit.app"
else
  echo "✓ built: $APP"
fi
