#!/usr/bin/env bash
# Capture an explicitly supplied command first, then bounded device logs.
# Interface: <scope> [window] [device]; RUN_CMD, BUNDLE, KEYWORD, DEVECOCLI_BIN.
# CAPTURE_HOST_ONLY=1 skips device access. RUN_CMD is an explicitly trusted shell command.
set +x
set -euo pipefail
umask 077
SCOPE="${1:-test}"
WINDOW="${2:-30m}"
DEVICE="${3:-}"
BUNDLE="${BUNDLE:-com.example.shuvi}"
KEYWORD="${KEYWORD:-}"
HOST_ONLY="${CAPTURE_HOST_ONLY:-0}"
DEVECOCLI_BIN="${DEVECOCLI_BIN:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v node >/dev/null 2>&1 || { printf '%s\n' '[error] existing Node runtime required' >&2; exit 1; }
SUPPORT="$ROOT/scripts/dev-run-support.cjs"
if [ "$HOST_ONLY" = 0 ]; then
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*) CLI_NAMES=(devecocli devecocli.cmd devecocli.exe) ;;
    *) CLI_NAMES=(devecocli) ;;
  esac
  if [ -z "$DEVECOCLI_BIN" ]; then
    for candidate in "${CLI_NAMES[@]}"; do
      if command -v "$candidate" >/dev/null 2>&1; then DEVECOCLI_BIN="$(command -v "$candidate")"; break; fi
    done
  fi
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
      if command -v "$DEVECOCLI_BIN" >/dev/null 2>&1; then DEVECOCLI_BIN="$(command -v "$DEVECOCLI_BIN")"; fi
      case "$DEVECOCLI_BIN" in /*) DEVECOCLI_BIN="$(cygpath -w "$DEVECOCLI_BIN")" ;; esac ;;
  esac
fi
OUT="$(node "$SUPPORT" evidence-dir "$ROOT" "$SCOPE")"
PRIVATE="$(node "$SUPPORT" private-temp "$ROOT")"
trap 'rm -rf "$PRIVATE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CMD_EXIT=not-run
CAPTURE_EXIT=0
if [ -n "${RUN_CMD:-}" ]; then
  CMD_EXIT=0
  "${BASH:-bash}" -c "$RUN_CMD" > "$PRIVATE/host.raw" 2>&1 || CMD_EXIT=$?
  node "$SUPPORT" public-output "$PRIVATE/host.raw" "$OUT/host.log" || CAPTURE_EXIT=$?
fi
LOG_EXIT=not-run
STATUS=skipped-host-only
if [ "$HOST_ONLY" = 0 ]; then
  LOG_EXIT=0
  # This array is always nonempty, safe under Bash 3.2 + nounset.
  LOG_ARGS=(log --bundle-name "$BUNDLE" --from "$WINDOW" --tail 20000)
  if [ -n "$DEVICE" ]; then LOG_ARGS+=(--device "$DEVICE"); fi
  node "$SUPPORT" invoke "$DEVECOCLI_BIN" "$PRIVATE/device.raw" "$PRIVATE/device.err" "${LOG_ARGS[@]}" || LOG_EXIT=$?
  node "$SUPPORT" public-output "$PRIVATE/device.raw" "$OUT/device.log" || CAPTURE_EXIT=$?
  node "$SUPPORT" public-output "$PRIVATE/device.err" "$OUT/log-diagnostic.log" || CAPTURE_EXIT=$?
  STATUS=ok
  if [ "$LOG_EXIT" -ne 0 ]; then STATUS=log-failed; fi
  if [ -n "$KEYWORD" ]; then node "$SUPPORT" filter "$OUT/device.log" "$OUT/filtered.log" "$KEYWORD" || CAPTURE_EXIT=$?; fi
elif [ "$HOST_ONLY" != 1 ]; then
  printf '%s\n' '[error] CAPTURE_HOST_ONLY must be 0 or 1' >&2
  exit 1
fi
META_EXIT=0
if [ "$CAPTURE_EXIT" -ne 0 ]; then STATUS=output-failed; fi
CAPTURE_BASH_VERSION="$BASH_VERSION" node "$SUPPORT" evidence-meta "$ROOT" "$OUT" "$SCOPE" "$WINDOW" "$DEVICE" "$BUNDLE" "$KEYWORD" "$CMD_EXIT" "$LOG_EXIT" "$STATUS" || META_EXIT=$?
printf '日志已落盘：%s（cmd_exit=%s，log_exit=%s，status=%s）\n' "$OUT" "$CMD_EXIT" "$LOG_EXIT" "$STATUS"
if [ "$CMD_EXIT" != not-run ] && [ "$CMD_EXIT" -ne 0 ]; then exit "$CMD_EXIT"; fi
if [ "$LOG_EXIT" != not-run ] && [ "$LOG_EXIT" -ne 0 ]; then exit "$LOG_EXIT"; fi
if [ "$CAPTURE_EXIT" -ne 0 ]; then exit "$CAPTURE_EXIT"; fi
exit "$META_EXIT"
