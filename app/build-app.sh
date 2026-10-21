#!/bin/bash
# Build Storage Watch into a self-contained .app bundle.
# Usage: ./build-app.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-build}"
APP="$OUT/Storage Watch.app"

SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk}"
export SDKROOT="$SDK"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/storagewatch-clang-cache}"

echo "▸ 编译 Swift（release）"
swift build -c release

echo "▸ 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/StorageWatch" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp ../engine/monitor.py "$APP/Contents/Resources/monitor.py"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP/Contents/Resources/"
cp Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

# Ad-hoc sign so Gatekeeper treats it as a consistent bundle on this Mac.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --identifier local.storagewatch.app "$APP/Contents/MacOS/StorageWatch" 2>/dev/null || true
codesign --force --sign - "$APP" 2>/dev/null || true

echo "✓ 完成：$APP"
echo "  双击运行，或拖入「应用程序」。首次启动会在菜单栏出现图标。"
