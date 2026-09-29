#!/usr/bin/env bash
# install.sh 가 만든 것을 되돌린다: LaunchAgent, funnel 경로, 데이터 폴더.
# Tailscale 자체(데몬·로그인·다른 serve/funnel 설정)는 건드리지 않는다.
#
# 사용법: server/uninstall.sh [--yes]
set -euo pipefail

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

warn() { printf '경고: %s\n' "$*" >&2; }
step() { printf '▶ %s\n' "$*"; }

if [[ $ASSUME_YES -eq 0 ]]; then
  printf '에이전트를 내리고 funnel 경로와 데이터 폴더(토큰 포함)를 삭제합니다.\n  %s\n계속할까요? [y/N] ' "$DATA_DIR"
  read -r answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then echo "취소했습니다."; exit 0; fi
fi

step "LaunchAgent 해제"
launchctl bootout "$DOMAIN/$SELF_LABEL" 2>/dev/null || echo "  (실행 중이 아님)"
rm -f "$PLIST"

step "funnel 경로 해제"
TOKEN=""
if [[ -s "$TOKEN_FILE" ]]; then TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"; fi
if [[ -z "$TOKEN" ]]; then
  echo "  (토큰 파일 없음 — 건너뜀)"
elif ! command -v tailscale >/dev/null; then
  warn "tailscale CLI 가 없어 funnel 경로 /$TOKEN 을 끄지 못했습니다."
# 가정: install.sh 와 같은 --https/--set-path 에 off 를 주면 그 경로만 해제된다.
elif ! tailscale funnel --https=8443 --set-path="/$TOKEN" off; then
  warn "funnel 경로 해제 실패 — 'tailscale funnel status' 로 확인 후 수동으로 끄세요."
fi

step "데이터 폴더 삭제"
rm -rf "$DATA_DIR"

echo
echo "제거 완료. 로그 파일은 남겨 뒀습니다: $LOG_FILE"
