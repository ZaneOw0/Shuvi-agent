#!/usr/bin/env bash
#
# Shuvi 本地一键启动脚本
# 职责：检测并补齐 设备/模拟器 -> 签名 -> 构建 -> 安装运行
#
# 用法:
#   scripts/dev-run.sh [选项]
#
# 选项:
#   --emulator <name>   指定模拟器名称（默认自动选择一个）
#   --device <serial>   指定设备序列号（多设备时使用）
#   --product <name>    产品名（默认 default）
#   --force-sign        强制重新生成签名材料
#   --no-build          跳过构建，仅安装运行
#   --no-emulator       不自动启动模拟器
#   -h, --help          显示帮助
#
# 环境变量:
#   EMULATOR_NAME       等价于 --emulator
#   PRODUCT             等价于 --product
#   DEVECOCLI_BIN       指定 devecocli 命令（默认自动探测 devecocli / devecocli.cmd / devecocli.exe）
#
# 说明:
#   签名材料生成在本机 ~/.ohos/config/，不会写入仓库。
#   build-profile.json5 以仓库中的模板为准（不含签名）；本机签名缓存在 .local/（不入库）。
#   脚本运行前由模板合成带签名版本，结束后自动还原为模板；模板变化时自动重新生成签名。
#   请勿把 signingConfigs / signingConfig 提交进仓库，pre-push 钩子会拦截。

set -euo pipefail

PRODUCT="${PRODUCT:-default}"
EMULATOR="${EMULATOR_NAME:-}"
DEVICE=""
FORCE_SIGN=0
NO_BUILD=0
NO_EMULATOR=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^#\{1\} \{0,1\}//'
}

strip_ansi() {
  sed "s/$(printf '\033')\[[0-9;]*m//g"
}

log() { printf '\n==> %s\n' "$*"; }

die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --emulator) [ $# -ge 2 ] || die "--emulator 缺少参数"; EMULATOR="$2"; shift 2 ;;
    --device)   [ $# -ge 2 ] || die "--device 缺少参数";   DEVICE="$2";   shift 2 ;;
    --product)  [ $# -ge 2 ] || die "--product 缺少参数";  PRODUCT="$2";  shift 2 ;;
    --force-sign)  FORCE_SIGN=1; shift ;;
    --no-build)    NO_BUILD=1; shift ;;
    --no-emulator) NO_EMULATOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
[ -f build-profile.json5 ] || die "未找到 build-profile.json5，请确认脚本位于仓库 scripts/ 目录下"

# 解析 devecocli 命令名：Git Bash 不按 PATHEXT 补后缀，Windows 上稳定形式常为 devecocli.cmd
DEVECOCLI_BIN="${DEVECOCLI_BIN:-}"
if [ -z "$DEVECOCLI_BIN" ]; then
  for _c in devecocli devecocli.cmd devecocli.exe; do
    if command -v "$_c" >/dev/null 2>&1; then DEVECOCLI_BIN="$_c"; break; fi
  done
fi
[ -n "$DEVECOCLI_BIN" ] || die "未找到 devecocli，请先安装 DevEco Code 命令行环境并加入 PATH，或设置 DEVECOCLI_BIN 指定命令"

# 启用仓库内钩子（仅仓库级配置，不影响全局）
if [ "$(git -C "$ROOT_DIR" config --local --get core.hooksPath 2>/dev/null || true)" != "scripts/hooks" ]; then
  if git -C "$ROOT_DIR" config --local core.hooksPath scripts/hooks 2>/dev/null; then
    log "已启用仓库钩子 core.hooksPath=scripts/hooks"
  fi
fi

has_device() { ! "$DEVECOCLI_BIN" device list 2>&1 | strip_ansi | grep -q "No active devices"; }

# 登录态预检：不代替用户登录，只在需要签名前给出明确提示
require_login() {
  local out
  out="$("$DEVECOCLI_BIN" auth status 2>&1)" || true
  printf '%s' "$out" | grep -q "Current user" && return 0
  die "未登录华为开发者账号。请先执行：devecocli auth login"
}

wait_ready() {
  local target="$1" waited=0
  while [ "$waited" -lt 240 ]; do
    "$DEVECOCLI_BIN" device view -t "$target" >/dev/null 2>&1 && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

TARGET=""

# 1. 设备 / 模拟器
if has_device; then
  log "检测到活动设备"
else
  [ "$NO_EMULATOR" = "0" ] || die "当前无活动设备，且指定了 --no-emulator。请连接真机或去掉该参数"

  log "未检测到活动设备，准备启动模拟器"
  if [ -z "$EMULATOR" ]; then
    EMULATOR="$("$DEVECOCLI_BIN" emulator list 2>/dev/null | strip_ansi | awk '$2=="running" || $2=="stopped" { print $1 }' | head -1)"
  fi
  [ -n "$EMULATOR" ] || die "未找到可用模拟器，请在 DevEco Studio > Device Manager 中创建"

  STATUS="$("$DEVECOCLI_BIN" emulator list 2>/dev/null | strip_ansi | awk -v n="$EMULATOR" '$1==n { print $2 }' | head -1)"
  if [ "$STATUS" != "running" ]; then
    log "启动模拟器 $EMULATOR"
    OUT="$("$DEVECOCLI_BIN" emulator start "$EMULATOR" 2>&1 | strip_ansi)" || true
    printf '%s\n' "$OUT"
    if printf '%s' "$OUT" | grep -q "license agreements are not accepted"; then
      die "模拟器许可协议未接受（通常只需手动接受一次，本脚本不代为同意）：
  交互式阅读全文后接受：devecocli emulator license
  直接接受：            devecocli emulator license accept"
    fi
    printf '%s' "$OUT" | grep -q "started successfully" || die "模拟器启动失败，请查看上方输出"
  else
    log "模拟器 $EMULATOR 已在运行"
  fi

  TARGET="$EMULATOR"
  log "等待设备完成启动（最多 240 秒）"
  wait_ready "$TARGET" || die "等待设备就绪超时"
fi

log "当前设备"
"$DEVECOCLI_BIN" device list 2>&1 | strip_ansi

# 2. 签名：由仓库模板合成带签名版本，脚本结束时还原模板
LOCAL_DIR="$ROOT_DIR/.local"
BP_FILE="$ROOT_DIR/build-profile.json5"
SIGNED_FILE="$LOCAL_DIR/build-profile.signed.json5"
SIGNED_SHA_FILE="$LOCAL_DIR/build-profile.template.sha"
BP_TEMPLATE_BAK="$LOCAL_DIR/build-profile.template.bak"

restore_build_profile() {
  if [ -n "${BP_TEMPLATE_BAK:-}" ] && [ -f "$BP_TEMPLATE_BAK" ]; then
    cp "$BP_TEMPLATE_BAK" "$BP_FILE" 2>/dev/null || true
    rm -f "$BP_TEMPLATE_BAK" 2>/dev/null || true
  fi
}
trap restore_build_profile EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_build_profile() {
  mkdir -p "$LOCAL_DIR"

  if grep -q "storeFile" "$BP_FILE" 2>/dev/null; then
    log "检测到 build-profile.json5 含本机签名，先还原为模板"
    git -C "$ROOT_DIR" checkout -- build-profile.json5
  fi

  git -C "$ROOT_DIR" diff --quiet -- build-profile.json5 || \
    die "build-profile.json5 有未提交改动。请先提交该共享配置改动，再运行本脚本"

  cp "$BP_FILE" "$BP_TEMPLATE_BAK"

  local tpl_sha
  tpl_sha="$(git -C "$ROOT_DIR" rev-parse "HEAD:build-profile.json5" 2>/dev/null || echo unknown)"

  if [ "$FORCE_SIGN" = "1" ] || [ ! -f "$SIGNED_FILE" ] || [ "$(cat "$SIGNED_SHA_FILE" 2>/dev/null || true)" != "$tpl_sha" ]; then
    require_login
    log "生成本机签名材料（product=$PRODUCT）"
    OUT="$("$DEVECOCLI_BIN" signature generate --product "$PRODUCT" 2>&1)" || {
      printf '%s\n' "$OUT"
      printf '%s' "$OUT" | grep -qiE "not logged in|auth login|sign in" && die "未登录华为开发者账号，请先执行：devecocli auth login"
      die "签名生成失败，请查看上方输出"
    }
    printf '%s\n' "$OUT"
    grep -q "storeFile" "$BP_FILE" || die "签名生成后 build-profile.json5 仍无签名配置"
    cp "$BP_FILE" "$SIGNED_FILE"
    printf '%s' "$tpl_sha" > "$SIGNED_SHA_FILE"
    log "本机签名已缓存到 .local/（不入库）"
  else
    log "复用 .local/ 中的本机签名缓存"
  fi

  cp "$SIGNED_FILE" "$BP_FILE"
  log "已由模板合成 build-profile.json5（含本机签名，脚本结束自动还原）"
}

prepare_build_profile

# 3. 构建
if [ "$NO_BUILD" = "1" ]; then
  log "跳过构建"
else
  log "构建"
  "$DEVECOCLI_BIN" build
fi

# 4. 安装运行
RUN_ARGS=(--skip-build)
if [ -n "$DEVICE" ]; then
  RUN_ARGS+=(--device "$DEVICE")
elif [ -n "$TARGET" ]; then
  RUN_ARGS+=(--device "$TARGET")
fi

log "安装并启动"
ATTEMPT=1
while true; do
  "$DEVECOCLI_BIN" run "${RUN_ARGS[@]}" && break
  [ "$ATTEMPT" -ge 3 ] && die "安装启动失败（已重试 3 次）"
  log "安装启动失败，第 $ATTEMPT 次重试"
  ATTEMPT=$((ATTEMPT + 1))
  sleep 10
done

log "完成"
printf '%s\n' "build-profile.json5 已还原为仓库模板；本机签名缓存在 .local/（不入库）。"
