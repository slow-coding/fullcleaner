#!/bin/bash
# 编译 → 自检 → 安装到 /Applications（用 ditto，保住 bundle 元数据，否则 Finder 会把它显示成文件夹）。
# 用法：./tools/install.sh [目标目录，默认 /Applications]

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="fullcleaner"
DISPLAY="FullCleaner"
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/$DISPLAY.app"

[ -x "build/$DISPLAY.app/Contents/MacOS/$NAME" ] || { echo "先跑 ./build.sh"; exit 1; }

echo "== 退出正在跑的那一个 =="
pkill -f "$DISPLAY.app/Contents/MacOS/$NAME" 2>/dev/null || true
sleep 1

echo "== 拷到 $DEST =="
rm -rf "$DEST"
ditto "build/$DISPLAY.app" "$DEST"           # cp -R 会丢 bundle 元数据：Finder 会显示成文件夹
SetFile -a B "$DEST"                          # 明确打 bundle 位
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

echo "== 校验 =="
codesign -v "$DEST" && echo "  签名有效"
KIND=$(osascript -e "tell application \"Finder\" to get kind of (POSIX file \"$DEST\" as alias)" 2>/dev/null || echo "?")
echo "  Finder 认它是：$KIND"

killall Finder 2>/dev/null || true
open "$DEST"
echo "  已启动。第一次打开如果被 Gatekeeper 拦（未公证的本地构建），右键 → 打开，或："
echo "  xattr -d com.apple.quarantine \"$DEST\""
