#!/bin/bash
# 编译 wallpaperengine-cli（web 壁纸 daemon）。
# 注意：assets 嵌入（zip_data.o）由 build-wallpaper-wgpu.sh 负责，CLI 不需要。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SRC_MAIN="$ROOT/wallpaperengine-cli.swift"
OUT_CLI="$ROOT/Resources/wallpaperengine-cli"

if [[ ! -f "$SRC_MAIN" ]]; then
  echo "error: missing $SRC_MAIN" >&2
  exit 1
fi

echo "[build-wallpaperengine-cli] swiftc..."
# -O -whole-module-optimization：Release 优化，避免 swiftc 默认 -Onone 产出
# 40M+ 的未优化二进制（曾导致发行版 DMG 体积异常膨胀）。
swiftc -parse-as-library \
  -O -whole-module-optimization \
  -target arm64-apple-macosx14.4 \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -framework AppKit -framework AVFoundation -framework IOKit -framework WebKit -framework Combine \
  -o "$OUT_CLI" \
  "$SRC_MAIN"

# strip 调试与本地符号，进一步减小体积（与仓库已提交的优化版对齐）
strip -x -S "$OUT_CLI" 2>/dev/null || true

if command -v codesign >/dev/null 2>&1; then
  echo "[build-wallpaperengine-cli] codesign (ad hoc)..."
  codesign --force -s - "$OUT_CLI" 2>/dev/null || true
fi

cp "$OUT_CLI" "$ROOT/wallpaperengine-cli"

echo "[build-wallpaperengine-cli] OK → $OUT_CLI"
