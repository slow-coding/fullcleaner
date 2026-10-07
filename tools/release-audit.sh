#!/bin/bash
# 发布前检查：个人信息 / 密钥 / 许可证 / 仓库卫生 / 构建 / 运行安全 / 文档 / 发布条件。
# 用法：./tools/release-audit.sh        （退出码 0 = 全部通过）
# 自觉一点：这些检查只覆盖能自动判的部分，判断类的（代码是不是自己写的、名字有没有撞车）人看。

set -uo pipefail
cd "$(dirname "$0")/.."

NAME="fullcleaner"
DISPLAY="FullCleaner"
PASS=0
FAIL=0
GREP_EXCLUDES=(--exclude-dir=.git --exclude-dir=build --exclude='*.png' --exclude='*.icns'
               --exclude='release-audit.sh' --exclude='private-patterns.local')

ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  – %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

# 命中为空的检查
expect_empty() { # 描述 命中内容
  if [ -z "${2:-}" ]; then ok "$1"; else bad "$1"; printf '%s\n' "$2" | head -5 | sed 's/^/      /'; fi
}

export LC_ALL=${LC_ALL:-en_US.UTF-8}
echo "$DISPLAY 发布前检查 · $(date '+%Y-%m-%d %H:%M')"

# ---------- 1. 个人信息 ----------
section "1. 个人信息不进仓库"
# 通用形态：本机绝对路径、常见邮箱服务商。项目自己的私有词表放 tools/private-patterns.local（已在 .gitignore 里）
PRIVATE_PATTERN='/Users/|@(gmail|outlook|hotmail|qq|163|126|icloud|me)\.'
LOCAL_PATTERNS_FILE="tools/private-patterns.local"
if [ -f "$LOCAL_PATTERNS_FILE" ]; then
  EXTRA=$(grep -vE '^\s*(#|$)' "$LOCAL_PATTERNS_FILE" | paste -sd'|' -)
  [ -n "$EXTRA" ] && PRIVATE_PATTERN="$PRIVATE_PATTERN|$EXTRA"
fi
[ -n "${OSS_PRIVATE_PATTERNS:-}" ] && PRIVATE_PATTERN="$PRIVATE_PATTERN|${OSS_PRIVATE_PATTERNS}" 
HITS=$(grep -rInE "$PRIVATE_PATTERN" "${GREP_EXCLUDES[@]}" . 2>/dev/null)
expect_empty "没有姓名 / 邮箱 / 用户名 / 机器名 / 本地绝对路径" "$HITS"

HITS=$(grep -rInE 'openId|open_id' "${GREP_EXCLUDES[@]}" . 2>/dev/null)
expect_empty "没有 openId 这类账号标识" "$HITS"

# ---------- 2. 密钥 ----------
section "2. 密钥不进仓库"
HITS=$(grep -rInE 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|sk-[A-Za-z0-9]{16,}|(api[_-]?key|secret|token|password|passwd)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}' "${GREP_EXCLUDES[@]}" . 2>/dev/null)
expect_empty "没有密钥 / 口令 / token 形态的字符串" "$HITS"

HITS=$(find . -name '.env*' -o -name 'auth.json' -o -name 'mcp.json' -o -name 'credentials*' 2>/dev/null | grep -v '^./build')
expect_empty "没有 .env / auth.json / 凭证文件" "$HITS"

# ---------- 3. 许可证 ----------
section "3. 许可证与来源"
[ -f LICENSE ] && ok "LICENSE 存在" || bad "LICENSE 缺失"
grep -q 'MIT License' LICENSE 2>/dev/null && ok "许可是 MIT" || bad "LICENSE 里没有 MIT 字样"
HITS=$(grep -nE "$PRIVATE_PATTERN" LICENSE 2>/dev/null)
expect_empty "版权行不含个人姓名 / 邮箱（占位为 contributors）" "$HITS"
HITS=$(grep -rIn --exclude='release-audit.sh' 'Copyright' src/ tools/ 2>/dev/null)
expect_empty "源码里没有第三方版权声明（自己写的，没夹带别人的代码）" "$HITS"

# ---------- 4. 仓库卫生 ----------
section "4. 仓库卫生"
grep -q '^build/' .gitignore 2>/dev/null && ok ".gitignore 挡掉 build/" || bad ".gitignore 没挡 build/"
grep -q 'DS_Store' .gitignore 2>/dev/null && ok ".gitignore 挡掉 .DS_Store" || bad ".gitignore 没挡 .DS_Store"
HITS=$(find . -name '.DS_Store' -not -path './build/*' 2>/dev/null)
expect_empty "仓库里没有 .DS_Store" "$HITS"
HITS=$(grep -rInE '\b(TODO|FIXME|XXX|HACK)\b' "${GREP_EXCLUDES[@]}" src/ tools/ 2>/dev/null)
expect_empty "源码里没有 TODO / FIXME 遗留" "$HITS"
HITS=$(find . -type f -size +5M -not -path './build/*' -not -path './.git/*' 2>/dev/null)
expect_empty "没有大于 5MB 的意外文件" "$HITS"

# ---------- 5. 构建 ----------
section "5. 构建"
if swiftc -O -swift-version 5 -parse-as-library -warnings-as-errors \
     -target arm64-apple-macosx13.0 src/*.swift -o /tmp/$NAME-audit-bin 2>/tmp/$NAME-audit-warn.txt; then
  ok "零告警编译（-warnings-as-errors）"
else
  bad "编译有告警或错误"; head -6 /tmp/$NAME-audit-warn.txt | sed 's/^/      /'
fi
BUILT=0
[ -x "build/$DISPLAY.app/Contents/MacOS/$NAME" ] && BUILT=1
if [ "$BUILT" = "1" ]; then
  # 通用二进制会让 otool 打两份（带 "(architecture …)" 行），先滤掉这些头
  # 通用二进制下 otool 会把两个架构各打一份，还夹着 "<路径> (architecture x86_64):" 这样的头行
  NON_SYSTEM=$(otool -L "build/$DISPLAY.app/Contents/MacOS/$NAME" | awk '$1 ~ /^\// {print $1}' \
                 | grep -vE '^/System/Library/|^/usr/lib/' || true)
  expect_empty "只链接系统框架（没有第三方 dylib）" "$NON_SYSTEM"
else
  skip "还没构建，跳过二进制检查（先跑 ./build.sh）"
fi

# ---------- 6. 运行安全（这工具会删文件，最重要的一节）----------
section "6. 运行安全"
SELFTEST=""
[ "$BUILT" = "1" ] && SELFTEST=$(./build/$DISPLAY.app/Contents/MacOS/$NAME --selftest 2>&1 || true)
if [ "$BUILT" != "1" ]; then
  skip "自检：未构建，跳过"
else
RESULT=$(printf '%s' "$SELFTEST" | grep -oE '结果：[0-9]+ 通过 · [0-9]+ 失败' | tail -1)
FAILED=$(printf '%s' "$RESULT" | grep -oE '[0-9]+ 失败' | grep -oE '^[0-9]+' || echo "")
if [ -n "$RESULT" ] && [ "${FAILED:-1}" = "0" ]; then ok "自检通过：$RESULT"; else bad "自检没通过：${RESULT:-没拿到结果}"; fi
printf '%s' "$SELFTEST" | grep -q '每一条都在样本目录里' && ok "自检里有「每条被删路径都在样本目录里」这条横断断言" || bad "缺这条断言"
# （下面两条同属自检结果，未构建时已在上面跳过）
printf '%s' "$SELFTEST" | grep -q '带引号与空格的路径删对了' && ok "自检验证了删除路径的引号转义（不会误删）" || bad "缺注入转义断言"
fi
grep -q 'trashItem' src/Remover.swift && ok "默认走废纸篓（FileManager.trashItem）" || bad "没看到废纸篓路径"
grep -q 'confirmed else' src/App.swift && ok "命令行卸载必须显式 --yes" || bad "命令行卸载没有 --yes 门"
# 只查「申请敏感能力」的 API。注意 kTCCServiceAppManagement 是只读查询自己的 App 管理状态，
# 属于本工具正当用途，不在禁止之列（早先一刀切写 kTCCService 造成过一次误报）。
HITS=$(grep -rInE 'AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|CNContactStore|EKEventStore|SFSpeechRecognizer|AVCaptureDevice|CLLocationManager|kTCCServiceAccessibility|kTCCServiceListenEvent|kTCCServiceScreenCapture' src/ 2>/dev/null)
expect_empty "不申请敏感权限（辅助功能 / 输入监控 / 录屏 / 通讯录 / 日历 / 语音 / 定位）" "$HITS"
HITS=$(grep -rInE 'URLSession|NSURLConnection|CFNetwork|Socket|https?://' src/ 2>/dev/null | grep -v 'x-apple.systempreferences' || true)
expect_empty "源码里没有联网调用" "$HITS"
[ -f tools/offline-test.sh ] && ok "带离线的可复跑校验脚本（tools/offline-test.sh）" || bad "缺离线校验脚本"

# ---------- 7. 文档 ----------
section "7. 文档"
for keyword in Overview Safety Usage Install Build Verification Limitations Privacy License; do
  grep -q "$keyword" README.md 2>/dev/null && ok "README has section 「${keyword}」" || bad "README misses section 「${keyword}」"
done
MISSING=0
for shot in $(grep -oE 'docs/[a-zA-Z0-9._-]+\.png' README.md | sort -u); do
  [ -f "$shot" ] || { MISSING=1; echo "      缺文件：$shot"; }
done
[ "$MISSING" -eq 0 ] && ok "README 里引用的截图都存在" || bad "README 引用了不存在的截图"
if [ "$BUILT" = "1" ]; then
  ./build/$DISPLAY.app/Contents/MacOS/$NAME --help 2>&1 | grep -q '用法' && ok "--help 有用法说明" || bad "--help 没有输出"
else
  skip "--help：未构建，跳过"
fi

# ---------- 8. 发布条件 ----------
section "8. 发布条件"
if [ -d .git ]; then
  ok "是 git 仓库"
  LOCAL_ID=$(git config --local user.email 2>/dev/null || true)
  LOCAL_NAME=$(git config --local user.name 2>/dev/null || true)
  if [ -z "$LOCAL_ID" ]; then
    skip "本地没设仓库身份（提交作者沿用全局配置）；真正的门是下面那条「提交作者是否干净」"
  elif printf '%s %s' "$LOCAL_NAME" "$LOCAL_ID" | grep -qE "$PRIVATE_PATTERN"; then
    bad "仓库身份像真实邮箱：${LOCAL_ID}（改成 GitHub 的 noreply 地址）"
  else
    ok "仓库身份不是个人邮箱：${LOCAL_NAME} <${LOCAL_ID}>"
  fi
  if [ -n "$(git log --oneline 2>/dev/null)" ]; then
    AUTHORS=$(git log --format='%ae' | sort -u | grep -E "$PRIVATE_PATTERN" || true)
    expect_empty "已有提交的作者邮箱都干净（没有真实邮箱进历史）" "$AUTHORS"
  else
    ok "还没有提交（首个提交前先确认身份）"
  fi
  TRACKED_BUILD=$(git ls-files | grep -c '^build/' || true)
  [ "$TRACKED_BUILD" = "0" ] && ok "版本库里没有 build/ 产物" || bad "build/ 被加进了版本库"
else
  bad "还不是 git 仓库（git init -b main）"
fi
[ -f .github/workflows/ci.yml ] && ok "有 CI（构建 + 自检 + 离线 + 本检查）" || bad "缺 CI 配置"

section "9. 全历史（推送公开仓库前必做）"
if [ -d .git ] && [ -n "$(git log --oneline 2>/dev/null)" ]; then
  # 两个名字都要排除：审计脚本天然含扫描用的正则行，改过名的话旧 blob 里也有
  HITS=$(git log -p --all -- . ':(exclude)tools/release-audit.sh' ':(exclude)tools/oss-audit.sh' 2>/dev/null \
         | grep -IE "$PRIVATE_PATTERN|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|sk-[A-Za-z0-9]{16,}" | head -8)
  expect_empty "全历史里没有个人信息与密钥形态（含被删过的文件）" "$HITS"
  HITS=$(git log --all --name-only --format= | sort -u | grep -E '^(build/|\.env|.*\.pem|.*\.key)' || true)
  expect_empty "历史里没有 build/ 产物与凭证文件" "$HITS"
  ok "历史共 $(git rev-list --all --count) 个提交，作者：$(git log --format='%ae' | sort -u | tr '\n' ' ')"
else
  bad "没有提交，无法扫描历史"
fi

echo ""
echo "结果：$PASS 通过 · $FAIL 未通过"
[ "$FAIL" -eq 0 ] && echo "可以发布。" || echo "先修掉上面标 ✗ 的。"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
