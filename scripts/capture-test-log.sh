#!/usr/bin/env bash
# 每次测试落盘：把设备日志与本次变更标识一起存档，便于按变更逐次追溯。
#
# 用法：
#   scripts/capture-test-log.sh <scope> [日志窗口] [设备]
# 例：
#   scripts/capture-test-log.sh s1-knowledge 40m
#   scripts/capture-test-log.sh s1-knowledge 20m Phone26
#
# 可用环境变量：
#   BUNDLE          应用包名（默认 com.example.shuvi）
#   KEYWORD         额外抓取一份按关键词过滤的日志
#   DEVECOCLI_BIN   devecocli 可执行文件（默认 devecocli）
#
# 输出：.cache/test-logs/<日期>-<scope>-<提交SHA>[-序号]/
#   meta.txt        本次运行的时间、设备、提交、工作区状态与指纹
#   device.log      原始设备日志
#   filtered.log    关键词过滤结果（设置了 KEYWORD 时）
# 同时在 .cache/test-logs/index.tsv 追加一行索引，供按时间/变更检索。
# .cache/ 已被 gitignore，日志属本机证据，不入库（原始日志路径可写入对应 spec）。

set -euo pipefail

SCOPE="${1:-test}"
WINDOW="${2:-30m}"
DEVICE="${3:-}"
BUNDLE="${BUNDLE:-com.example.shuvi}"
KEYWORD="${KEYWORD:-}"
DEVECOCLI_BIN="${DEVECOCLI_BIN:-devecocli}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DATE="$(date +%Y-%m-%d)"
STAMP="$(date '+%F %T')"
SHA="$(git rev-parse --short HEAD 2>/dev/null || printf 'nogit')"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '-')"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
WORKTREE="$( { git diff; git diff --cached; } 2>/dev/null | sha1sum | cut -c1-12 )"
BASE="${DATE}-${SCOPE}-${SHA}"
OUT=".cache/test-logs/${BASE}"
SUFFIX=2
while [ -e "$OUT" ]; do
  OUT=".cache/test-logs/${BASE}-${SUFFIX}"
  SUFFIX=$((SUFFIX + 1))
done
mkdir -p "$OUT"

DEVICE_ARGS=()
if [ -n "$DEVICE" ]; then
  DEVICE_ARGS=(--device "$DEVICE")
fi

STATUS="ok"
if ! "$DEVECOCLI_BIN" log --bundle-name "$BUNDLE" --from "$WINDOW" --tail 20000 \
  "${DEVICE_ARGS[@]}" > "$OUT/device.log" 2>&1; then
  STATUS="log-failed"
fi

CMD_STATUS="not-run"
if [ -n "${RUN_CMD:-}" ]; then
  if bash -c "$RUN_CMD" > "$OUT/host.log" 2>&1; then
    CMD_STATUS="ok"
  else
    CMD_STATUS="failed"
  fi
fi

if [ -n "$KEYWORD" ]; then
  grep -F "$KEYWORD" "$OUT/device.log" > "$OUT/filtered.log" || true
fi

TEMPLATE_MARKER="$(grep -Ec '"signingConfigs"[[:space:]]*:[[:space:]]*\[\]|signingConfigs:[[:space:]]*\[\]' build-profile.json5 2>/dev/null || true)"
TEMPLATE_STATE="signed-or-modified"
if [ "$TEMPLATE_MARKER" -ge 1 ]; then
  TEMPLATE_STATE="template"
fi

{
  printf 'run_at\t%s\n' "$STAMP"
  printf 'scope\t%s\n' "$SCOPE"
  printf 'branch\t%s\n' "$BRANCH"
  printf 'commit\t%s\n' "$SHA"
  printf 'dirty_files\t%s\n' "$DIRTY"
  printf 'worktree_fingerprint\t%s\n' "$WORKTREE"
  printf 'bundle\t%s\n' "$BUNDLE"
  printf 'device\t%s\n' "${DEVICE:-auto}"
  printf 'log_window\t%s\n' "$WINDOW"
  printf 'keyword\t%s\n' "${KEYWORD:--}"
  printf 'status\t%s\n' "$STATUS"
  printf 'build_profile\t%s\n' "$TEMPLATE_STATE"
  printf 'run_cmd\t%s\n' "${RUN_CMD:--}"
  printf 'run_cmd_status\t%s\n' "$CMD_STATUS"
} > "$OUT/meta.txt"

mkdir -p .cache/test-logs
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$STAMP" "$SCOPE" "$SHA" "$DIRTY" "$WORKTREE" "$BUNDLE" "$OUT" >> .cache/test-logs/index.tsv

printf '日志已落盘：%s（status=%s，commit=%s，工作区改动=%s）\n' "$OUT" "$STATUS" "$SHA" "$DIRTY"
