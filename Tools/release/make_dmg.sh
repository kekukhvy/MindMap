#!/bin/zsh
# Builds a Release macOS app from the given source tree (default: repo root) and writes ~/Desktop/MindMap.dmg.
set -euo pipefail
SRC="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="$SRC/build/DD-release"
# Team-signed (iCloud/CloudKit) when a Mac provisioning profile exists, else a local ad-hoc build
# without CloudKit (see Tools/xcb/xcb.sh).
"$SRC/Tools/xcb/xcb.sh" -project "$SRC/MindMap.xcodeproj" -scheme MindMap -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" build -quiet
APP="$DD/Build/Products/Release/MindMap.app"
codesign --verify --deep --strict "$APP"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="$HOME/Desktop/MindMap.dmg"
rm -f "$OUT"
hdiutil create -volname "MindMap" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "$OUT ($(git -C "$SRC" rev-parse --short HEAD))"
