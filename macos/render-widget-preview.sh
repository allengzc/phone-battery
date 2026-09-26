#!/usr/bin/env bash
# Render the widget design offscreen to PNGs for inspection.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$HERE/.cache"
OUT="$HERE/preview"
mkdir -p "$CACHE" "$OUT"

TMPDIR="$CACHE" swiftc -O -parse-as-library \
  -module-cache-path "$CACHE/modules" \
  -Xcc -fmodules-cache-path="$CACHE/clang" \
  -framework SwiftUI -framework AppKit \
  "$HERE/Widget/WidgetView.swift" "$HERE/Widget/Preview.swift" \
  -o "$CACHE/widget-preview"

"$CACHE/widget-preview" "$OUT"
ls -la "$OUT"
