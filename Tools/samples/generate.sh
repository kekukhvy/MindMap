#!/bin/sh
# Regenerates the WP9 sample maps with the real model + package writer
# (MindMapTests/SampleMapGenerator.swift) and copies them into the repo.
# The hosted tests run in the app sandbox, so they write to the container tmp.
set -e
cd "$(dirname "$0")/../.."
OUT="$HOME/Library/Containers/com.kekukh.MindMap/Data/tmp/Samples"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MindMap.xcodeproj -scheme MindMap \
  -destination 'platform=macOS' -derivedDataPath build/DD test \
  -only-testing:MindMapTests/SampleMapGeneratorTests | grep -E "error|Test .*(passed|failed)|SNAPSHOT|SAMPLES" || true
test -f "$OUT/features-map.png"
mkdir -p Samples Tools/preview
for map in "MindMap Features.mindmap" "MindMap Roadmap.mindmap"; do
  rm -rf "Samples/$map"
  cp -R "$OUT/$map" "Samples/$map"
done
cp "$OUT/features-map.png" Tools/preview/features-map.png
echo "Wrote Samples/ and Tools/preview/features-map.png"
