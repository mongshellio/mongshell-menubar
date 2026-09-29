#!/usr/bin/env bash
# Tests for server/install.sh's option rules (server/lib.sh): validation, the
# saved `options` file, and precedence (command line > saved > default).
#
# Each case pins a rule whose mutation would silently change what a re-run
# installs — the trap being `git pull && server/install.sh` reverting options.
#
# Run with `./scripts/test.sh`, which sources the real lib.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

die()  { printf '오류: %s\n' "$*" >&2; exit 1; }
warn() { printf '경고: %s\n' "$*" >&2; }
# shellcheck source=../../server/lib.sh
source "$ROOT/server/lib.sh"

FAILURES=()
CASES=0
check() { # $1=label, $2=expected, $3=actual
  CASES=$((CASES + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf ' FAIL  %s  — expected [%s], got [%s]\n' "$1" "$2" "$3"
    FAILURES+=("$1")
  fi
}

OPTS="$WORK/options"
# $1=file contents ("" → no file), $2=ARG_INTERVAL, $3=ARG_AUTO_HEAL.
# Prints "<interval> <auto_heal> <warned 0|1>".
resolve() {
  rm -f "$OPTS"
  [[ -n "$1" ]] && printf '%b' "$1" >"$OPTS"
  ARG_INTERVAL="$2" ARG_AUTO_HEAL="$3"
  load_saved_options "$OPTS" 2>"$WORK/err"
  resolve_options
  printf '%s %s %s' "$INTERVAL" "$AUTO_HEAL" "$([[ -s "$WORK/err" ]] && echo 1 || echo 0)"
}

echo "▸ 우선순위 (명시 > 저장 > 기본)"
check "파일 없음 → 기본 60·켬"            "60 1 0" "$(resolve "" "" "")"
check "저장 30 + 명시 없음 → 30"          "30 1 0" "$(resolve 'interval=30\n' "" "")"
check "저장 30 + 명시 45 → 45" "45 1 0" "$(resolve 'interval=30\n' 45 "")"
check "auto_heal=0 저장 + 명시 없음 → 끔" "60 0 0" "$(resolve 'auto_heal=0\n' "" "")"
check "명시 켬(--auto-heal)이 저장 0 을 덮음" "60 1 0" "$(resolve 'auto_heal=0\n' "" 1)"
check "명시 끔(--no-auto-heal)이 저장 1 을 덮음" "30 0 0" "$(resolve 'interval=30\nauto_heal=1\n' "" 0)"

echo "▸ 깨진 저장값 → 경고 후 기본"
check "interval=abc → 60 + 경고"          "60 1 1" "$(resolve 'interval=abc\n' "" "")"
check "auto_heal=2 → 켬 + 경고"           "60 1 1" "$(resolve 'auto_heal=2\n' "" "")"
check "auto_heal=00 → 켬 + 경고"          "60 1 1" "$(resolve 'auto_heal=00\n' "" "")"
# 2^64 + 30: without the digit cap, bash arithmetic wraps it to an in-range 30.
check "20자리 숫자 무시 (오버플로로 30 이 되는 값)" "60 1 1" "$(resolve 'interval=18446744073709551646\n' "" "")"
check "범위 밖 14 무시"                   "60 1 1" "$(resolve 'interval=14\n' "" "")"
check "범위 밖 86401 무시"                "60 1 1" "$(resolve 'interval=86401\n' "" "")"
check "경계 15 허용"                "15 1 0" "$(resolve 'interval=15\n' "" "")"
check "경계 86400 허용"                   "86400 1 0" "$(resolve 'interval=86400\n' "" "")"
check "앞자리 0 은 10진수 (045 → 45)"     "45 1 0" "$(resolve 'interval=045\n' "" "")"
check "끝줄 개행 없어도 읽음"             "30 0 0" "$(resolve 'interval=30\nauto_heal=0' "" "")"
check "모르는 키 무시"                    "30 1 0" "$(resolve 'foo=bar\ninterval=30\n' "" "")"

rm -f "$WORK/pwned"
resolve "interval=\$(touch $WORK/pwned)\n" "" "" >/dev/null
check "파일 내용을 실행하지 않음" "absent" "$([[ -e "$WORK/pwned" ]] && echo present || echo absent)"

echo ""
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  echo "✓ $CASES cases passed"
else
  echo "✗ ${#FAILURES[@]}/$CASES failed: $(IFS=,; echo "${FAILURES[*]}")"
  exit 1
fi
