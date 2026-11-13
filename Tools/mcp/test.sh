#!/bin/bash
# Builds the server, then drives the real binary over stdio on COPIES of Samples/ (tests AC-mcp-1..11).
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/model-sources.sh"
"$HERE/build.sh" >/dev/null
OUT="$HERE/.build"
swiftc -O -module-name mindmap_mcp_tests -o "$OUT/mindmap-mcp-tests" "${MODEL_SOURCES[@]}" "$HERE"/Tests/*.swift
"$OUT/mindmap-mcp-tests" "$(cd "$HERE/../.." && pwd)" "$OUT/mindmap-mcp"
