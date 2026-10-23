#!/usr/bin/env bash
#
# Shuvi macOS 专用启动脚本（Bash 3.2 / macOS）；不改动 scripts/dev-run.sh。
#
# 流程与 dev-run.sh 一致：设备/模拟器 -> 登录预检 -> 许可预检 -> 启动并等待就绪
#                        -> 签名合成 -> 构建 -> 安装运行
# 与 dev-run.sh 的差异：
#   - 仅 macOS；目标选择用 CLI 的 JSON 清单，实例名含空格安全，不按空格切表格
#   - 不执行任何 Git 写操作（不 checkout、不设置 hooksPath）；模板脏或含签名时停止
#   - 登录与模拟器许可协议显式预检；本脚本不代为登录、不代为接受协议
#
# 用法:
#   scripts/dev-run-mac.sh [选项]
#
# 选项:
#   --emulator <完整名称>   指定模拟器（默认：唯一活动设备，否则清单首个模拟器）
#   --device <serial|名称>  指定已连接设备或已在运行的模拟器
#   --product <name>        产品名（默认 default）
#   --no-build              跳过构建，用已有产物安装运行
#   --no-emulator           不自动启动已停止的模拟器
#   -h, --help              帮助
#
# 环境变量: EMULATOR_NAME、PRODUCT、DEVECOCLI_BIN
#

set -euo pipefail
umask 077

PRODUCT="${PRODUCT:-default}"
EMULATOR="${EMULATOR_NAME:-}"
DEVICE=""
NO_BUILD=0
NO_EMULATOR=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
log() { printf '\n==> %s\n' "$*"; }
note() { printf '\n[提示] %s\n' "$*" >&2; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --emulator) [ $# -ge 2 ] && [ -n "$2" ] || die "--emulator 缺少参数"; EMULATOR="$2"; shift 2 ;;
    --device)   [ $# -ge 2 ] && [ -n "$2" ] || die "--device 缺少参数";   DEVICE="$2";   shift 2 ;;
    --product)  [ $# -ge 2 ] && [ -n "$2" ] || die "--product 缺少参数";  PRODUCT="$2";  shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    --no-emulator) NO_EMULATOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "本脚本仅支持 macOS；其他平台请用 scripts/dev-run.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
[ -f build-profile.json5 ] || die "未找到 build-profile.json5，请确认脚本位于仓库 scripts/ 目录"
command -v node >/dev/null 2>&1 || die "需要 Node 运行时（解析 CLI JSON 清单）"
command -v git >/dev/null 2>&1 || die "需要 Git（只读校验模板状态）"

CLI="${DEVECOCLI_BIN:-}"
if [ -z "$CLI" ] && command -v devecocli >/dev/null 2>&1; then CLI="$(command -v devecocli)"; fi
[ -n "$CLI" ] || die "未找到 devecocli；请安装 DevEco Code 命令行或设置 DEVECOCLI_BIN"

STATE_DIR="$ROOT_DIR/.local"
LOG_DIR="$STATE_DIR/mac-run"
mkdir -p "$LOG_DIR"
chmod 700 "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
TPL_BAK="$STATE_DIR/mac-run.template.bak"

# 工具原始输出只落 .local/mac-run/（不入库、不回显），公共输出只有阶段、RC 与类别。
# CLI 会在 postAction 把版本提醒追加到 stdout（如 "New version 1.3.5 available, ..."），
# 破坏 JSON 消费；用官方开关关闭检查，同时解析层仍容忍该提醒（见 JSON_READER），不依赖单一机制。
CLI_RUN=("$CLI")
cli_private() {
  local phase="$1"; shift
  DEVECO_CLI_DISABLE_UPDATE=check DEVECO_CLI_SKIP_VERSION_CHECK=1 \
    "${CLI_RUN[@]}" "$@" > "$LOG_DIR/$phase.out" 2> "$LOG_DIR/$phase.err"
}
private_hint() { printf '（工具输出保留在 %s）' "$LOG_DIR"; }
grep_private() { grep -Eqi "$1" "$LOG_DIR/$2.out" "$LOG_DIR/$2.err" 2>/dev/null; }

JSON_READER='
const fs = require("node:fs");
const NOTICE = /^New version \d+(\.\d+)* available, run `devecocli update` to upgrade$/;
function readJson(path) {
  const lines = fs.readFileSync(path, "utf8").split("\n");
  while (lines.length > 0) {
    const tail = lines[lines.length - 1].trim();
    if (tail !== "" && !NOTICE.test(tail)) break;
    lines.pop();
  }
  return JSON.parse(lines.join("\n"));
}
'
READ_DEVICES='
let list;
try { list = readJson(process.argv[1]); } catch { process.exit(2); }
if (!Array.isArray(list)) process.exit(3);
for (const item of list) {
  if (!item || typeof item.name !== "string" || typeof item.serial !== "string") process.exit(4);
  if (item.kind !== "device" && item.kind !== "emulator") process.exit(5);
  console.log([item.name, item.serial, item.kind].join("\t"));
}
'
READ_EMULATORS='
let list;
try { list = readJson(process.argv[1]); } catch { process.exit(2); }
if (!Array.isArray(list)) process.exit(3);
for (const item of list) {
  if (!item || typeof item.name !== "string") process.exit(4);
  if (item.status !== "running" && item.status !== "stopped") process.exit(5);
  if (item.serial !== null && typeof item.serial !== "string") process.exit(6);
  console.log([item.name, item.status, item.serial || "", item.deviceType || "", item.osVersion || ""].join("\t"));
}
'
tsv_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'; }
has_serial() { printf '%s\n' "$1" | awk -F'\t' -v s="$2" '$2==s {found=1} END {exit found?0:1}'; }
emulator_row() { printf '%s\n' "$EMULATOR_ROWS" | awk -F'\t' -v n="$1" '$1==n {print; exit}'; }

refresh_inventories() {
  cli_private device-list device list --format json || die "读取设备清单失败$(private_hint)"
  cp "$LOG_DIR/device-list.out" "$LOG_DIR/devices.json"
  DEVICE_ROWS="$(node -e "${JSON_READER}${READ_DEVICES}" "$LOG_DIR/devices.json")" || die "设备清单 JSON 无效（阶段: device list）"
  cli_private emulator-list emulator list --format json || die "读取模拟器清单失败$(private_hint)"
  cp "$LOG_DIR/emulator-list.out" "$LOG_DIR/emulators.json"
  EMULATOR_ROWS="$(node -e "${JSON_READER}${READ_EMULATORS}" "$LOG_DIR/emulators.json")" || die "模拟器清单 JSON 无效（阶段: emulator list）"
}

# 模拟器许可状态是 CLI 自己的状态文件（只读探针，作提示用）；权威判定是启动时的 CLI 报错。
license_state() {
  local cfg state=unknown
  for cfg in "$HOME"/Library/Caches/Huawei/Emulator*/.emu_config; do
    [ -f "$cfg" ] || continue
    if grep -qiE '^[[:space:]]*HarmonyOS_SDK_Agreement[[:space:]]*[:=][[:space:]]*agree[[:space:]]*$' "$cfg"; then
      state=agree
    elif grep -qiE '^[[:space:]]*HarmonyOS_SDK_Agreement[[:space:]]*[:=]' "$cfg"; then
      state=not-accepted
    fi
  done
  printf '%s' "$state"
}
license_help() {
  printf '%s\n' '本脚本不代为同意协议，请先在本机执行其一：' \
    '  交互式阅读全文后接受: devecocli emulator license' \
    '  直接接受:             devecocli emulator license accept'
}

# 1. 登录预检（签名材料必须由已登录的本机工具生成）
log "检查登录状态（CLI: ${CLI}）"
AUTH_OUT="$(DEVECO_CLI_DISABLE_UPDATE=check DEVECO_CLI_SKIP_VERSION_CHECK=1 "$CLI" auth status 2>&1 || true)"
AUTH_OUT="$(printf '%s' "$AUTH_OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"
case "$AUTH_OUT" in
  *"Current user:"*) log '登录状态: 已登录' ;;
  *)
    AUTH_HINT=''
    if [ -n "${DEVECO_CLI_AUTH_SOURCE:-}${DEVECO_CODE_AUTH_DIR:-}" ]; then
      AUTH_HINT='（检测到继承的 DEVECO_CLI_AUTH_SOURCE/DEVECO_CODE_AUTH_DIR，可能改变登录解析；请在独立终端运行，或用 DEVECOCLI_BIN 指向独立 CLI）'
    fi
    die "未登录华为开发者账号。请先执行：devecocli auth login${AUTH_HINT}" ;;
esac

# 2. 设备 / 模拟器
log '读取设备与模拟器清单'
refresh_inventories

DEVICE_ROW=""
if [ -n "$DEVICE" ]; then
  DEVICE_ROW="$(printf '%s\n' "$DEVICE_ROWS" | awk -F'\t' -v k="$DEVICE" '$2==k {print; exit}')"
  if [ -z "$DEVICE_ROW" ]; then
    MATCHED="$(printf '%s\n' "$DEVICE_ROWS" | awk -F'\t' -v k="$DEVICE" '$1==k {print}')"
    MATCH_COUNT="$(printf '%s\n' "$MATCHED" | grep -c . || true)"
    [ "$MATCH_COUNT" -le 1 ] || die "名称 '$DEVICE' 匹配多个实例，请改用 serial"
    DEVICE_ROW="$MATCHED"
  fi
fi

SELECT_NAME=""; SELECT_SERIAL=""; TARGET_MODE=""
if [ -n "$EMULATOR" ]; then
  EMU_ROW="$(emulator_row "$EMULATOR")"
  [ -n "$EMU_ROW" ] || die "模拟器清单中没有 '$EMULATOR'（名称含空格时整体加引号）"
  SELECT_NAME="$EMULATOR"
  EMU_STATUS="$(tsv_field "$EMU_ROW" 2)"
  EMU_SERIAL="$(tsv_field "$EMU_ROW" 3)"
  if [ -n "$DEVICE" ]; then
    [ -n "$DEVICE_ROW" ] || die "--device '$DEVICE' 不在设备清单中，拒绝启动无关实例"
    [ "$(tsv_field "$DEVICE_ROW" 3)" = "emulator" ] || die "--device 与 --emulator 指向不同实例"
    [ "$(tsv_field "$DEVICE_ROW" 1)" = "$SELECT_NAME" ] || die "--device 与 --emulator 指向不同实例"
    [ "$EMU_STATUS" = "running" ] && [ -n "$EMU_SERIAL" ] && [ "$EMU_SERIAL" = "$(tsv_field "$DEVICE_ROW" 2)" ] \
      || die "--device 与 --emulator 指向不同实例"
    SELECT_SERIAL="$EMU_SERIAL"; TARGET_MODE=wait
  elif [ "$EMU_STATUS" = "running" ] && [ -n "$EMU_SERIAL" ]; then
    SELECT_SERIAL="$EMU_SERIAL"; TARGET_MODE=wait
  else
    [ "$NO_EMULATOR" = 0 ] || die "指定了 --no-emulator，但实例 '$SELECT_NAME' 未在运行"
    TARGET_MODE=start
  fi
elif [ -n "$DEVICE" ]; then
  [ -n "$DEVICE_ROW" ] || die "设备清单中没有 '$DEVICE'"
  SELECT_NAME="$(tsv_field "$DEVICE_ROW" 1)"
  SELECT_SERIAL="$(tsv_field "$DEVICE_ROW" 2)"
  [ "$(tsv_field "$DEVICE_ROW" 3)" = "emulator" ] || TARGET_MODE=device
  if [ -z "$TARGET_MODE" ]; then
    EMU_ROW="$(emulator_row "$SELECT_NAME")"
    [ -n "$EMU_ROW" ] && [ "$(tsv_field "$EMU_ROW" 3)" = "$SELECT_SERIAL" ] || die "模拟器清单与设备清单矛盾，停止"
    TARGET_MODE=wait
  fi
else
  DEVICE_COUNT="$(printf '%s\n' "$DEVICE_ROWS" | grep -c . || true)"
  if [ "$DEVICE_COUNT" -gt 1 ]; then die '存在多个活动设备，请用 --device 或 --emulator 明确指定'; fi
  if [ "$DEVICE_COUNT" = 1 ]; then
    SELECT_NAME="$(tsv_field "$DEVICE_ROWS" 1)"
    SELECT_SERIAL="$(tsv_field "$DEVICE_ROWS" 2)"
    [ "$(tsv_field "$DEVICE_ROWS" 3)" = "emulator" ] || TARGET_MODE=device
    if [ -z "$TARGET_MODE" ]; then
      EMU_ROW="$(emulator_row "$SELECT_NAME")"
      [ -n "$EMU_ROW" ] && [ "$(tsv_field "$EMU_ROW" 3)" = "$SELECT_SERIAL" ] || die "模拟器清单与设备清单矛盾，停止"
      TARGET_MODE=wait
    fi
  else
    EMU_ROW="$(printf '%s\n' "$EMULATOR_ROWS" | grep . | head -1 || true)"
    [ -n "$EMU_ROW" ] || die '没有活动设备，也没有可启动的模拟器实例'
    SELECT_NAME="$(tsv_field "$EMU_ROW" 1)"
    if [ "$(tsv_field "$EMU_ROW" 2)" = "running" ] && [ -n "$(tsv_field "$EMU_ROW" 3)" ]; then
      SELECT_SERIAL="$(tsv_field "$EMU_ROW" 3)"; TARGET_MODE=wait
    else
      [ "$NO_EMULATOR" = 0 ] || die '当前无活动设备，且指定了 --no-emulator'
      TARGET_MODE=start
    fi
  fi
fi

if [ "$TARGET_MODE" = start ]; then
  LICENSE_STATE="$(license_state)"
  case "$LICENSE_STATE" in
    agree) log '模拟器许可协议: 已接受' ;;
    not-accepted) printf '%s\n' "$(license_help)" >&2; die "模拟器许可协议未接受，无法启动实例 '$SELECT_NAME'" ;;
    *) note '未能从本机状态确认模拟器许可，若因许可失败会给出明确提示' ;;
  esac
  log "启动模拟器：$SELECT_NAME"
  if cli_private emulator-start emulator start -- "$SELECT_NAME"; then :; else
    if grep_private 'license agreements are not accepted' emulator-start; then
      printf '%s\n' "$(license_help)" >&2
      die "模拟器许可协议未接受，无法启动实例 '$SELECT_NAME'"
    fi
    die "模拟器启动失败$(private_hint)"
  fi
  if grep_private 'license agreements are not accepted' emulator-start; then
    printf '%s\n' "$(license_help)" >&2
    die "模拟器许可协议未接受，无法启动实例 '$SELECT_NAME'"
  fi
  if grep_private 'did not appear in hdc list targets' emulator-start; then
    note 'CLI 报告实例已拉起但暂未进入 hdc，继续等待（冷启动可能较慢）'
  fi
fi

# 3. 等待就绪并锁定 serial
TARGET_SERIAL="$SELECT_SERIAL"
if [ "$TARGET_MODE" != device ]; then
  log "等待 '$SELECT_NAME' 就绪（最多 240 秒）"
  DEADLINE=$((SECONDS + 240))
  while :; do
    refresh_inventories
    EMU_ROW="$(emulator_row "$SELECT_NAME")"
    [ -n "$EMU_ROW" ] || die "模拟器 '$SELECT_NAME' 从清单中消失，停止"
    if [ "$(tsv_field "$EMU_ROW" 2)" = "running" ] && [ -n "$(tsv_field "$EMU_ROW" 3)" ]; then
      if has_serial "$DEVICE_ROWS" "$(tsv_field "$EMU_ROW" 3)"; then
        TARGET_SERIAL="$(tsv_field "$EMU_ROW" 3)"; break
      fi
    fi
    [ "$SECONDS" -lt "$DEADLINE" ] || die '等待设备就绪超时（240 秒）'
    sleep 5
  done
fi
cli_private device-view device view -t "$TARGET_SERIAL" --format json || die "device view 失败$(private_hint)"
node -e '
const fs = require("node:fs");
const info = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!info || info.serial !== process.argv[2]) process.exit(1);
' "$LOG_DIR/device-view.out" "$TARGET_SERIAL" || die 'device view 与锁定 serial 不一致'
log "已锁定目标: serial=$TARGET_SERIAL"

# 4. 签名：由仓库模板合成带签名版本，退出时还原（不做任何 Git 写操作）
git -C "$ROOT_DIR" ls-files --error-unmatch -- build-profile.json5 >/dev/null 2>&1 \
  || die 'build-profile.json5 未被 Git 跟踪；请先提交模板再运行'
git -C "$ROOT_DIR" diff --quiet -- build-profile.json5 || die 'build-profile.json5 有未提交改动，请先提交'
git -C "$ROOT_DIR" diff --cached --quiet -- build-profile.json5 || die 'build-profile.json5 已暂存改动，请先提交'
grep -q 'storeFile' build-profile.json5 && die 'build-profile.json5 已含本机签名；请先在 Git 中恢复无签名模板'

restore_template() {
  local rc="$?"
  trap - EXIT
  if [ -f "$TPL_BAK" ]; then
    cp "$TPL_BAK" build-profile.json5
    if ! cmp -s "$TPL_BAK" build-profile.json5; then
      printf '\n[错误] 模板恢复核验失败：%s 保留，请人工核对\n' "$TPL_BAK" >&2
      exit 1
    fi
    rm -f "$TPL_BAK"
  fi
  exit "$rc"
}
cp build-profile.json5 "$TPL_BAK"
trap restore_template EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TPL_SHA="$(shasum -a 256 build-profile.json5 | awk '{print $1}')"
SIGN_CACHE="$STATE_DIR/mac-run.$PRODUCT.$TPL_SHA.json5"
cache_valid=0
if [ -f "$SIGN_CACHE" ]; then
  # 签名配置由 CLI 以 JSON5 风格写出（无引号键、单引号值），按文本校验材料路径存在，
  # 不做严格 JSON.parse（否则缓存永不命中，每次都会重新生成签名）。
  node -e '
const fs = require("node:fs");
const text = fs.readFileSync(process.argv[1], "utf8");
if (!/signingConfigs\s*:/.test(text)) process.exit(1);
for (const key of ["storeFile", "certpath", "profile"]) {
  const found = new RegExp("\\b" + key + "\\s*:\\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]").exec(text);
  if (!found) process.exit(2);
  if (!fs.existsSync(found[1]) || !fs.statSync(found[1]).isFile()) process.exit(3);
}
' "$SIGN_CACHE" && cache_valid=1
fi
if [ "$cache_valid" = 1 ]; then
  log "复用本机签名缓存（product=${PRODUCT}）"
else
  log "生成本机签名材料（product=${PRODUCT}）"
  SIGN_RC=0
  cli_private signature signature generate --product "$PRODUCT" || SIGN_RC=$?
  if [ "$SIGN_RC" -ne 0 ]; then
    if grep_private 'not logged in|auth login|sign in|invalid accesstoken' signature; then
      die '未登录华为开发者账号。请先执行：devecocli auth login'
    fi
    printf '\n[错误] 签名生成失败（RC=%s）%s\n' "$SIGN_RC" "$(private_hint)" >&2
    exit "$SIGN_RC"
  fi
  grep -q 'storeFile' build-profile.json5 || die "签名生成后 build-profile.json5 仍无签名配置$(private_hint)"
  cp build-profile.json5 "$SIGN_CACHE"
fi
cp "$SIGN_CACHE" build-profile.json5
log '已由模板合成 build-profile.json5（含本机签名，脚本结束自动还原）'

# 5. 构建
if [ "$NO_BUILD" = 1 ]; then
  log '跳过构建（使用已有产物）'
else
  log "构建（product=${PRODUCT}）"
  BUILD_RC=0
  cli_private build build --product "$PRODUCT" || BUILD_RC=$?
  if [ "$BUILD_RC" -ne 0 ]; then
    if grep_private 'sign|provision|certificate|identity' build; then
      printf '\n[错误] 构建失败：疑似签名或证书问题（RC=%s）%s\n' "$BUILD_RC" "$(private_hint)" >&2
      exit "$BUILD_RC"
    fi
    printf '\n[错误] 构建失败（RC=%s）%s\n' "$BUILD_RC" "$(private_hint)" >&2
    exit "$BUILD_RC"
  fi
  log '构建成功（CLI 退出码 0）'
fi

# 6. 安装并启动（始终指定锁定 serial，不允许回退到其他设备）
ATTEMPT=1
while :; do
  log "安装并启动：serial=${TARGET_SERIAL}（第 ${ATTEMPT} 次）"
  RUN_RC=0
  cli_private run run --skip-build --product "$PRODUCT" --device "$TARGET_SERIAL" || RUN_RC=$?
  [ "$RUN_RC" -eq 0 ] && break
  if grep_private 'device.*(offline|not ready)|connection.*(reset|timed out)' run && [ "$ATTEMPT" -lt 3 ]; then
    note '临时连接问题，10 秒后重试'
    ATTEMPT=$((ATTEMPT + 1))
    sleep 10
    continue
  fi
  printf '\n[错误] 安装启动失败（RC=%s）%s\n' "$RUN_RC" "$(private_hint)" >&2
  exit "$RUN_RC"
done
SUCCESS=1
log '安装启动完成（CLI 退出码 0；应用运行状态需另行确认）'
