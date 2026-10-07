#!/bin/bash
# 编译 → 静态检查（不联网）→ 图标 → 组装 .app → 自检 → 打 dmg → 挂载验证。
# 用法：./build.sh    （产出 build/FullCleaner.app 与 build/FullCleaner-<版本>.dmg）

set -euo pipefail
cd "$(dirname "$0")"

NAME="fullcleaner"        # 可执行文件名、bundle id、命令行提示里用的小写名
DISPLAY="FullCleaner"     # Finder 与界面上显示的名字
VERSION="0.5.0"
BUILD="build"
APP="$BUILD/$DISPLAY.app"
DMG="$BUILD/$DISPLAY-$VERSION.dmg"

echo "== 1/6 编译（通用二进制：Apple 芯片 + Intel）=="
mkdir -p "$BUILD"
rm -rf "$APP" "$BUILD/$NAME" "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64"
compile() {  # $1 架构 target，$2 输出
  local out
  out=$(swiftc -O -swift-version 5 -parse-as-library -target "$1" src/*.swift -o "$2" 2>&1 || true)
  # 命令行工具里的 Swift 兼容库只有 arm64 切片，编 x86_64 时会刷这两行警告；不是错
  printf '%s\n' "$out" | grep -v "libswiftCompatibilityPacks" | grep -E "error|warning" || true
  [ -f "$2" ] || { printf '%s\n' "$out"; echo "  编 $1 失败"; exit 1; }
}
compile arm64-apple-macosx13.0 "$BUILD/$NAME-arm64"
compile x86_64-apple-macosx13.0 "$BUILD/$NAME-x86_64"
lipo -create "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64" -output "$BUILD/$NAME"
rm -f "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64"
echo "  二进制 $(du -h "$BUILD/$NAME" | cut -f1) · 架构 $(lipo -archs "$BUILD/$NAME")"

echo "== 2/6 静态检查：不接受联网代码 =="
if grep -nE "URLSession|NSURLConnection|CFNetwork|NSURLRequest|Socket|Network\.framework|https?://" src/*.swift > /tmp/fullcleaner-net.txt; then
  echo "  发现联网相关代码："; cat /tmp/fullcleaner-net.txt; exit 1
fi
echo "  源码里没有联网调用"

echo "== 2b/6 二进制检查：不链接网络框架、没有网络符号、没有网址 =="
if otool -L "$BUILD/$NAME" | grep -qE "CFNetwork|/Network\.framework|WebKit"; then
  echo "  链接了网络框架，停下"; exit 1
fi
if nm -u "$BUILD/$NAME" 2>/dev/null | grep -qiE "urlsession|cfnetwork|_socket|_connect|_getaddrinfo|nw_connection"; then
  echo "  有网络相关符号，停下"; exit 1
fi
if strings -a "$BUILD/$NAME" | grep -qE "^https?://"; then
  echo "  二进制里有网址，停下"; exit 1
fi
echo "  未链接 CFNetwork/Network，无网络符号，无网址"

echo "== 3/6 图标 =="
swiftc -O tools/makeicon.swift -o "$BUILD/makeicon"
rm -rf "$BUILD/icon.iconset"
"$BUILD/makeicon" "$BUILD/icon.iconset" > /dev/null
iconutil -c icns "$BUILD/icon.iconset" -o "$BUILD/AppIcon.icns"
echo "  $(ls "$BUILD/icon.iconset" | wc -l | tr -d ' ') 个尺寸 → AppIcon.icns"

echo "== 4/6 组装 .app =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  echo "  Developer ID 签名：$SIGN_IDENTITY（强化运行时 + 时间戳）"
else
  codesign --force --options runtime --sign - "$APP" 2>/dev/null
  echo "  ad-hoc 签名（本机自用；要分发给别人就跑 ./tools/release.sh）"
fi

echo "== 5/6 自检（临时样本目录里跑完整的判据与删除流程）=="
"$APP/Contents/MacOS/$NAME" --selftest | tail -4

echo "== 6/6 打 dmg 并挂载验证 =="
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE" "$BUILD/mnt"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$(basename "$APP")"   # 用 ditto：cp -R 会丢 bundle 元数据，Finder 会把它显示成文件夹
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$DISPLAY $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
mkdir -p "$BUILD/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$BUILD/mnt" "$DMG"
"$BUILD/mnt/$DISPLAY.app/Contents/MacOS/$NAME" --selftest | tail -1
codesign -v "$BUILD/mnt/$DISPLAY.app" && echo "  挂载出来的 app 签名有效"
hdiutil detach -quiet "$BUILD/mnt"
# 暂存目录里的那份会被 LaunchServices 记住（哪怕目录已删），顺手注销掉
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$STAGE/$DISPLAY.app" 2>/dev/null || true
rm -rf "$STAGE" "$BUILD/mnt" "$BUILD/icon.iconset" "$BUILD/makeicon"

echo ""
echo "产物："
echo "  $APP"
echo "  $DMG  ($(du -h "$DMG" | cut -f1))"
