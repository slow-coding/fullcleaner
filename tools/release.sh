#!/bin/bash
# 出一条可以直接发给用户的 dmg：
#   通用二进制（arm64 + x86_64）→ Developer ID 签名（强化运行时 + 时间戳）→ 公证 → 装订 → 校验 → dist/
#
# 用法：
#   ./tools/release.sh                 # 自动找钥匙串里的 Developer ID 证书
#   ./tools/release.sh --identity "Developer ID Application: 名字 (TEAMID)"
#   ./tools/release.sh --dry-run       # 只打印每一步要跑的命令，不动手（没有证书也能看流程）
#
# 还没有证书的话，先做三件事（一次性）：
#   1. 加入 Apple Developer Program（个人/公司 99 美元/年）
#   2. 在 developer.apple.com → Certificates 里建一张 Developer ID Application 证书，装进钥匙串
#      （或在 Xcode → Settings → Accounts → Manage Certificates 里点 + 选 Developer ID Application）
#   3. 存公证凭据：见 tools/notarize.sh 顶部那两行命令

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "用法：./tools/release.sh [--identity \"Developer ID Application: …\"] [--dry-run]"; exit 2 ;;
  esac
done

run() {
  if [ "$DRY_RUN" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

VERSION=$(grep -E '^VERSION=' build.sh | head -1 | sed 's/.*"\(.*\)".*/\1/')
APP="build/FullCleaner.app"
DMG="build/FullCleaner-$VERSION.dmg"
DIST="dist/FullCleaner-$VERSION.dmg"
BIN="$APP/Contents/MacOS/fullcleaner"

SIGN_IDENTITY="${IDENTITY:-${SIGN_IDENTITY:-}}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true)
fi

echo "FullCleaner 发行 · 版本 $VERSION"
echo "  签名身份：${SIGN_IDENTITY:-（没找到）}"
echo ""

if [ -z "$SIGN_IDENTITY" ] && [ "$DRY_RUN" != "1" ]; then
  cat <<'EOF'
钥匙串里没有 Developer ID Application 证书。要出可发布的包，先做：
  1. 加入 Apple Developer Program（99 美元/年）：https://developer.apple.com/programs/
  2. 建证书：developer.apple.com → Certificates, Identifiers & Profiles → Certificates → + → Developer ID Application
     下载 .cer 双击装进钥匙串；或在 Xcode → Settings → Accounts → Manage Certificates 里点 + 选它
  3. 存公证凭据（Apple ID + App 专用密码 + Team ID）：
     xcrun notarytool store-credentials fullcleaner-notary \
       --apple-id "你的 Apple ID" --team-id "你的 Team ID" --password "app 专用密码"
然后重跑 ./tools/release.sh。
现在也可以先跑 ./tools/release.sh --dry-run 看整条流程。
EOF
  exit 1
fi

echo "== 1. 编译 + 签名 =="
run env SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh

echo "== 2. 核签名与加固运行时 =="
if [ "$DRY_RUN" = "1" ]; then
  printf '  [dry-run] codesign -dvvv %s\n' "$APP"
  printf '  [dry-run] lipo -archs %s\n' "$BIN"
  printf '  [dry-run] spctl -a -vvv %s\n' "$APP"
else
  lipo -archs "$BIN" | sed 's/^/  架构：/'
  codesign -dvvv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|flags=" | sed 's/^/  /'
  codesign -dvvv "$APP" 2>&1 | grep -q "flags=.*runtime" && echo "  强化运行时：已开" || { echo "  ✗ 强化运行时没开（公证会被拒）"; exit 1; }
  codesign -dvvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
    || { echo "  ✗ 不是 Developer ID 签的（ad-hoc 签名的包不能公证）"; exit 1; }
  spctl -a -vvv "$APP" 2>&1 | sed 's/^/  /' || true
fi

echo "== 3. 公证 + 装订 =="
run ./tools/notarize.sh "$DMG"

echo "== 4. 归档到 dist/ =="
run mkdir -p dist
run cp "$DMG" "$DIST"
if [ "$DRY_RUN" != "1" ]; then
  echo "  sha256：$(shasum -a 256 "$DIST" | cut -d' ' -f1)"
  echo "  体积：$(du -h "$DIST" | cut -f1)"
fi

echo ""
echo "发出去就是这个文件：$DIST"
echo "公证过的包，用户下载后双击就能打开（不再需要右键 → 打开）。"
