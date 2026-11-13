#!/bin/bash
# Builds Tools/mcp/.build/mindmap-mcp from the app's model sources (referenced in place) + Tools/mcp/Sources.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/model-sources.sh"
OUT="$HERE/.build"
mkdir -p "$OUT"
swiftc -O -warnings-as-errors -module-name mindmap_mcp -o "$OUT/mindmap-mcp" "${MODEL_SOURCES[@]}" "$HERE"/Sources/*.swift
echo "built $OUT/mindmap-mcp"
