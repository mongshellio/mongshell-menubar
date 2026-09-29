#!/usr/bin/env bash
# install.sh 가 만든 것을 되돌린다: LaunchAgent, funnel 경로, 데이터 폴더.
# Tailscale 자체(데몬·로그인·다른 serve/funnel 설정)는 건드리지 않는다.
#
# 사용법: server/uninstall.sh [--yes]
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PRODUCT="mongshell-openclaw-agent"
SELF_LABEL="com.mongshell.openclaw-agent"
DATA_DIR="$HOME/Library/Application Support/$PRODUCT"
TOKEN_FILE="$DATA_DIR/token"
PLIST="$HOME/Library/LaunchAgents/$SELF_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/$PRODUCT.log"
DOMAIN="gui/$(id -u)"

ASSUME_YES=0
case "${1:-}" in
  "") ;;
  -y|--yes) ASSUME_YES=1 ;;
  -h|--help) echo "사용법: $0 [--yes]"; exit 0 ;;
  *) echo "알 수 없는 인자: $1" >&2; exit 1 ;;
esac

die()  { printf '\n오류: %s\n' "$*" >&2; exit 1; }
step() { printf '▶ %s\n' "$*"; }

if [[ $ASSUME_YES -eq 0 ]]; then
  printf '에이전트를 내리고 funnel 경로와 데이터 폴더(토큰 포함)를 삭제합니다.\n  %s\n계속할까요? [y/N] ' "$DATA_DIR"
  read -r answer || answer=""
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then echo "취소했습니다."; exit 0; fi
fi

# 공개 경로를 가장 먼저 내린다. 해제를 확인하지 못하면 아무것도 지우지 않고
# 중단한다 — 토큰 파일이 남아 있어야 다시 실행해 같은 경로를 찾아 끌 수 있다.
step "funnel 경로 해제"
TOKEN=""
if [[ -s "$TOKEN_FILE" ]]; then TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"; fi
if [[ -z "$TOKEN" ]]; then
  echo "  (토큰 파일 없음 — 건너뜀)"
elif ! pgrep -x tailscaled >/dev/null; then
  # --bg 로 저장한 funnel 설정은 데몬이 다시 뜨면 되살아난다. 지금 해제하지 못하면
  # 토큰 파일이 남아 있어야 나중에 같은 경로를 찾아 끌 수 있다.
  die "tailscaled 가 돌고 있지 않아 funnel 경로를 해제할 수 없습니다 (저장된 공개 설정은 데몬 재기동 시 되살아납니다). tailscaled 를 켠 뒤 다시 실행하세요."
else
  TAILSCALE="$(command -v tailscale || true)"
  [[ -n "$TAILSCALE" ]] \
    || die "tailscaled 는 돌고 있는데 tailscale CLI 가 PATH 에 없어 공개 경로를 끌 수 없습니다. PATH 를 확인하고 다시 실행하세요."
  DNS_NAME="$("$TAILSCALE" status --json 2>/dev/null | plutil -extract Self.DNSName raw -o - - 2>/dev/null || true)"
  DNS_NAME="${DNS_NAME%.}"
  [[ -n "$DNS_NAME" ]] \
    || die "이 기기의 MagicDNS 이름을 얻지 못해 공개 경로를 확인할 수 없습니다. 'tailscale status' 를 확인하세요."
  # 가정: install.sh 와 같은 --https/--set-path 에 off 를 주면 그 경로만 해제된다.
  unpublish_path "$TAILSCALE" "$DNS_NAME:$FUNNEL_PORT" "/$TOKEN"
  echo "  → 해제 확인"
fi

step "LaunchAgent 해제"
launchctl bootout "$DOMAIN/$SELF_LABEL" 2>/dev/null || echo "  (실행 중이 아님)"
rm -f "$PLIST"

step "데이터 폴더 삭제"
rm -rf "$DATA_DIR"

echo
echo "제거 완료. 로그 파일은 남겨 뒀습니다: $LOG_FILE"
