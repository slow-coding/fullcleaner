#!/bin/bash
# 离线验证：真跑一次扫描与出清单，全程每 0.2 秒采样一次这个进程树的网络连接，必须 0 条。
# 用法：./tools/offline-test.sh [目标应用名或 bundle id] [采样秒数，默认 25]

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="fullcleaner"
BIN="build/$NAME"
[ -x "$BIN" ] || { echo "先跑 ./build.sh（找不到 $BIN）"; exit 1; }

TARGET="${1:-}"
SECONDS_TO_RUN="${2:-25}"

echo "== 1/3 源码：不接受联网代码 =="
if grep -nE "URLSession|NSURLConnection|CFNetwork|NSURLRequest|Socket|Network\.framework|https?://" src/*.swift > /tmp/fullcleaner-offline-src.txt; then
  echo "  发现联网相关代码："; cat /tmp/fullcleaner-offline-src.txt; exit 1
fi
echo "  0 处"

echo "== 2/3 二进制：未链接网络框架、无网络符号、无网址 =="
if otool -L "$BIN" | grep -qE "CFNetwork|/Network\.framework|WebKit"; then echo "  链接了网络框架"; exit 1; fi
if nm -u "$BIN" 2>/dev/null | grep -qiE "urlsession|cfnetwork|_socket|_connect|_getaddrinfo|nw_connection"; then echo "  有网络符号"; exit 1; fi
if strings -a "$BIN" | grep -qE "^https?://"; then echo "  有网址"; exit 1; fi
echo "  通过"

echo "== 3/3 运行期：真实扫描期间的连接采样 =="
if [ -n "$TARGET" ]; then
  "$BIN" --plan "$TARGET" > /tmp/fullcleaner-offline-run.log 2>&1 &
else
  "$BIN" --list > /tmp/fullcleaner-offline-run.log 2>&1 &
fi
PID=$!
SAMPLES=0
HITS=0
START=$(date +%s)
while kill -0 "$PID" 2>/dev/null; do
  SAMPLES=$((SAMPLES + 1))
  CONNECTIONS=$(lsof -a -p "$PID" -i 2>/dev/null | tail -n +2 || true)
  if [ -n "$CONNECTIONS" ]; then
    HITS=$((HITS + 1))
    echo "  发现连接："; echo "$CONNECTIONS"
  fi
  if [ $(( $(date +%s) - START )) -gt "$SECONDS_TO_RUN" ]; then echo "  采样超时，先收摊"; kill "$PID" 2>/dev/null || true; break; fi
  sleep 0.2
done
wait "$PID" 2>/dev/null || true

echo "  采样 $SAMPLES 次，网络连接 $HITS 条"
echo "  运行输出摘要："
sed -n '1,5p' /tmp/fullcleaner-offline-run.log | sed 's/^/    /'
if [ "$HITS" -ne 0 ]; then echo "  结论：有网络活动，不算离线"; exit 1; fi
echo "  结论：全程 0 条网络连接"
