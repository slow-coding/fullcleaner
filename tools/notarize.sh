#!/bin/bash
# 提交 Apple 公证（notarization）并装订票据（staple）。
# 公证过了，用户下载后双击就能开，不会再有「未验证的开发者」提示。
#
# 用法：
#   ./tools/notarize.sh build/FullCleaner-0.1.0.dmg
#   ./tools/notarize.sh build/FullCleaner-0.1.0.dmg --profile my-profile
#   ./tools/notarize.sh build/FullCleaner-0.1.0.dmg --dry-run
#
# 一次性准备（每台机器一次）：把 Apple ID + 专用密码 + Team ID 存进钥匙串
#   xcrun notarytool store-credentials fullcleaner-notary \
#     --apple-id "你的 Apple ID" --team-id "你的 Team ID" --password "app 专用密码"
# 专用密码在 https://account.apple.com → 登录与安全 → App 专用密码（不是 Apple ID 密码）。

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="fullcleaner-notary"
DRY_RUN=0
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] && [ -f "$TARGET" ] || { echo "用法：./tools/notarize.sh <dmg|zip> [--profile 名字] [--dry-run]"; exit 2; }

run() {
  if [ "$DRY_RUN" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

echo "== 0. 前置检查 =="
if ! xcrun -f notarytool >/dev/null 2>&1; then
  echo "  找不到 notarytool（需要 Xcode 或较新的命令行工具）"; exit 1
fi
echo "  notarytool: $(xcrun -f notarytool)"

if [ "$DRY_RUN" != "1" ]; then
  if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null 2>&1; then
    cat <<EOF
  钥匙串里没有公证凭据「$PROFILE」。先跑一次：
    xcrun notarytool store-credentials $PROFILE \\
      --apple-id "你的 Apple ID" --team-id "你的 Team ID" --password "app 专用密码"
EOF
    exit 1
  fi
  echo "  公证凭据：$PROFILE ✓"
fi

echo "== 1. 提交公证（这一步要等 Apple 回，通常 1~5 分钟）=="
LOG=$(mktemp)
if [ "$DRY_RUN" = "1" ]; then
  printf '  [dry-run] xcrun notarytool submit %s --keychain-profile %s --wait --output-format json\n' "$TARGET" "$PROFILE"
  STATUS="dry-run"
  SUBMIT_ID="dry-run"
else
  xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait --output-format json > "$LOG"
  STATUS=$(python3 -c "import json,sys; print(json.load(open('$LOG')).get('status',''))" 2>/dev/null || echo "?")
  SUBMIT_ID=$(python3 -c "import json,os; print(json.load(open('$LOG')).get('id',''))" 2>/dev/null || echo "")
  echo "  结果：$STATUS（id $SUBMIT_ID）"
  if [ "$STATUS" != "Accepted" ]; then
    echo "  公证没通过，拉 Apple 的日志："
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$PROFILE" || true
    rm -f "$LOG"; exit 1
  fi
fi
rm -f "$LOG"

echo "== 2. 装订票据（用户离线也能验）=="
run xcrun stapler staple "$TARGET"
run xcrun stapler validate "$TARGET"

echo "== 3. Gatekeeper 校验（这一步过了，用户双击就能开）=="
if [ "$DRY_RUN" = "1" ]; then
  printf '  [dry-run] spctl -a -vvv -t open --context context:primary-signature %s\n' "$TARGET"
else
  spctl -a -vvv -t open --context context:primary-signature "$TARGET" 2>&1 | sed 's/^/  /'
fi
echo ""
echo "公证完成：$TARGET"
