#!/bin/zsh
# Renders the Welcome Tour pictures (WP13) with the real canvas from the bundled
# "MindMap Features" sample (MindMapTests/TourImageGenerator.swift) plus iPad
# simulator screenshots from Tools/preview, and copies them into the asset
# catalog as Tour1…Tour6. The hosted test runs in the app sandbox: inputs go to
# and outputs come from the app container's tmp folder.
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP="$HOME/Library/Containers/com.kekukh.MindMap/Data/tmp"
mkdir -p "$TMP/TourInput"
cp Tools/preview/touch-palette-ipad.png Tools/preview/handwriting-ipad.png Tools/preview/note-sheet-ipad.png "$TMP/TourInput/"
rm -rf "$TMP/Tour"
Tools/xcb/xcb.sh -project MindMap.xcodeproj -scheme MindMap -destination 'platform=macOS' \
  -derivedDataPath build/DD test -only-testing:MindMapTests/TourImageGenerator \
  | grep -E "error|Test .*(passed|failed)|TOUR" || true
for n in 1 2 3 4 5 6; do
  test -f "$TMP/Tour/tour-$n.png"
  set_dir="MindMap/Assets.xcassets/Tour$n.imageset"
  mkdir -p "$set_dir"
  # 2400x1440 PNG → shipped at 2x (1200x720 pt).
  cp "$TMP/Tour/tour-$n.png" "$set_dir/tour-$n@2x.png"
  cat > "$set_dir/Contents.json" <<JSON
{
  "images": [
    {"filename": "tour-$n@2x.png", "idiom": "universal", "scale": "2x"}
  ],
  "info": {"author": "xcode", "version": 1}
}
JSON
done
rm -rf "$TMP/TourInput"
echo "Wrote MindMap/Assets.xcassets/Tour1…Tour6"
