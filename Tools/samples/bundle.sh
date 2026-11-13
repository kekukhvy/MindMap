#!/bin/zsh
# Bundles the COMMITTED sample maps (git HEAD:Samples/, never uncommitted edits)
# into the app resources MindMap/Resources/sample-features.json / sample-roadmap.json
# (WP13: copied into the user's store on the first launch / "Open Sample").
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git archive HEAD Samples | tar -x -C "$TMP"
mkdir -p MindMap/Resources
xcrun swift Tools/samples/bundle_package.swift "$TMP/Samples/MindMap Features.mindmap" MindMap/Resources/sample-features.json
xcrun swift Tools/samples/bundle_package.swift "$TMP/Samples/MindMap Roadmap.mindmap" MindMap/Resources/sample-roadmap.json
