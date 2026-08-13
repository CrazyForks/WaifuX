#!/bin/bash
# 编译 wallpaper-video-renderer（视频壁纸独立渲染子进程）
# 产出 Resources/wallpaper-video-renderer 和仓库根 wallpaper-video-renderer 两份
# 用法：./scripts/build-wallpaper-video-renderer.sh

set -euo pipefail

cd "$(dirname "$0")/.."

echo "[1/4] swiftc 编译 wallpaper-video-renderer..."
swiftc -parse-as-library \
  -O -whole-module-optimization \
  -target arm64-apple-macosx14.4 \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -framework AppKit -framework AVFoundation -framework CoreGraphics -framework Combine -framework ExceptionHandling \
  -o Resources/wallpaper-video-renderer \
  wallpaper-video-renderer.swift

echo "[2/4] strip..."
strip -x -S Resources/wallpaper-video-renderer

echo "[3/4] codesign (ad-hoc)..."
codesign --force -s - Resources/wallpaper-video-renderer

echo "[4/4] 复制到仓库根（防 Xcode 开发时根目录优先加载）..."
cp Resources/wallpaper-video-renderer wallpaper-video-renderer

echo "✅ wallpaper-video-renderer 编译完成"
ls -lh Resources/wallpaper-video-renderer wallpaper-video-renderer
