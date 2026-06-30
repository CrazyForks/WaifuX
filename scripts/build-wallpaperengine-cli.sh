#!/bin/bash
# 将 Resources/assets 打成 zip，编译进 wallpaperengine-cli（通过汇编 .incbin 嵌入 Mach-O）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASSETS_DIR="$ROOT/Resources/assets"
SRC_MAIN="$ROOT/wallpaperengine-cli.swift"
SRC_EMBED="$ROOT/WallpaperEngineEmbeddedAssets.swift"
OUT_CLI="$ROOT/Resources/wallpaperengine-cli"
TMP_ZIP="/tmp/waifux-we-assets-$$.zip"
TMP_DIR="$(mktemp -d -t waifux-we-build-XXXXXX)"
rm -f "$TMP_ZIP"

cleanup() { rm -rf "$TMP_ZIP" "$TMP_DIR"; }
# 注意：Resources/{zip_data.s,zip_data.o,zip_accessor.c,zip_accessor.o} 是仓库 committed
# 文件，App 主程序也会通过 OTHER_LDFLAGS 链接 zip_data.o + zip_accessor.o（见
# WaifuX.xcodeproj/project.pbxproj 与 WallpaperEngineEmbeddedAssets.swift）。
# 早期版本会在脚本结束时一并删除它们，但这样会让随后的 xcodebuild 因缺 .o 链接失败。
# 这里只清理临时 zip，保留生成的 .s/.c/.o 留作 App 构建输入。
trap cleanup EXIT

if [[ ! -f "$SRC_MAIN" || ! -f "$SRC_EMBED" ]]; then
  echo "error: missing Swift sources" >&2
  exit 1
fi

HAS_ASSETS=false
if [[ -d "$ASSETS_DIR" ]] && [[ -n "$(ls -A "$ASSETS_DIR" 2>/dev/null)" ]]; then
  HAS_ASSETS=true
fi

if [[ "$HAS_ASSETS" == true ]]; then
  echo "[build-wallpaperengine-cli] Zipping assets..."
  ( cd "$ROOT/Resources" && zip -r -q "$TMP_ZIP" assets )
else
  echo "[build-wallpaperengine-cli] 无 assets，构建空资源占位"
  echo -n "" > "$TMP_ZIP"
fi

echo "[build-wallpaperengine-cli] 生成汇编文件嵌入 zip..."
cat > "$ROOT/Resources/zip_data.s" << EOF
	.globl _zip_data_start
	.globl _zip_data_end
_zip_data_start:
	.incbin "$TMP_ZIP"
_zip_data_end:
EOF

as -arch arm64  -mmacosx-version-min=14.4 "$ROOT/Resources/zip_data.s" -o "$TMP_DIR/zip_data_arm64.o"
as -arch x86_64 -mmacosx-version-min=14.4 "$ROOT/Resources/zip_data.s" -o "$TMP_DIR/zip_data_x86_64.o"
# 主 App 是 universal (arm64 + x86_64)，链接时两份切片都需要；
# 早先只产 arm64 单切片会让 x86_64 archive 阶段报 "Undefined symbols _get_zip_data_ptr"。
lipo -create "$TMP_DIR/zip_data_arm64.o" "$TMP_DIR/zip_data_x86_64.o" -output "$ROOT/Resources/zip_data.o"

echo "[build-wallpaperengine-cli] 生成 C bridge..."
cat > "$ROOT/Resources/zip_accessor.c" << 'EOF'
#include <stdint.h>
#include <stddef.h>

extern uint8_t zip_data_start[];
extern uint8_t zip_data_end[];

uint8_t* get_zip_data_ptr(void) { return zip_data_start; }
size_t get_zip_data_size(void) { return (size_t)(zip_data_end - zip_data_start); }
EOF

clang -c -arch arm64 -arch x86_64 -mmacosx-version-min=14.4 "$ROOT/Resources/zip_accessor.c" -o "$ROOT/Resources/zip_accessor.o"

echo "[build-wallpaperengine-cli] swiftc..."
swiftc -parse-as-library \
  -target arm64-apple-macosx14.4 \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -framework AppKit -framework AVFoundation -framework IOKit -framework WebKit -framework Combine \
  -o "$OUT_CLI" \
  "$SRC_MAIN" "$SRC_EMBED" \
  "$ROOT/Resources/zip_data.o" "$ROOT/Resources/zip_accessor.o"

if command -v codesign >/dev/null 2>&1; then
  echo "[build-wallpaperengine-cli] codesign (ad hoc)..."
  codesign --force -s - "$OUT_CLI" 2>/dev/null || true
fi

cp "$OUT_CLI" "$ROOT/wallpaperengine-cli"

echo "[build-wallpaperengine-cli] OK → $OUT_CLI"
